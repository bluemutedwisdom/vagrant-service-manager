require_relative 'os'
require 'digest'

module Vagrant
  module ServiceManager
    DOCKER_PATH = '/home/vagrant/.docker'
    SUPPORTED_SERVICES = ['docker', 'openshift', 'kubernetes']
    SCCLI_SERVICES = ['openshift', 'k8s']
    KUBE_NAMES = ['kubernetes', 'k8s']
    KUBE_SERVICES = [
      "etcd",
      "kube-apiserver",
      "kube-controller-manager",
      "kube-scheduler",
      "kubelet",
      "kube-proxy",
      "docker"
    ]

    class Command < Vagrant.plugin(2, :command)
      OS_RELEASE_FILE = '/etc/os-release'

      def self.synopsis
        I18n.t('servicemanager.synopsis')
      end

      def exit_if_machine_not_running
        # Exit from plugin with status 3 if machine is not running
        with_target_vms(nil, {:single_target=>true}) do |machine|
          if machine.state.id != :running
            @env.ui.error I18n.t('servicemanager.machine_should_running')
            exit 3
          end
        end
      end

      def execute
        command, subcommand, option = ARGV[1..ARGV.length]

        case command
        when 'env'
          exit_if_machine_not_running
          case subcommand
          when 'docker'
            case option
            when nil
              execute_docker_info
            when '--script-readable'
              execute_docker_info(true)
            when '--help', '-h'
              print_help(type: command)
            else
              print_help(type: command, exit_status: 1)
            end
          when 'openshift'
            case option
            when nil
              execute_openshift_info
            when '--script-readable'
              execute_openshift_info(true)
            when '--help', '-h'
              print_help(type: command)
            else
              print_help(type: command, exit_status: 1)
            end
          when nil
            # display information about all the providers inside ADB/CDK
            print_all_provider_info
          when '--script-readable'
            print_all_provider_info(true)
          when '--help', '-h'
            print_help(type: command)
          else
            print_help(type: command, exit_status: 1)
          end
        when 'status'
          case subcommand
          when nil
            execute_status_display
          when '--help', '-h'
            print_help(type: command)
          else
            execute_status_display(subcommand)
          end
        when 'box'
          exit_if_machine_not_running
          case subcommand
          when 'version'
            case option
            when nil
              print_vagrant_box_version
            when '--script-readable'
              print_vagrant_box_version(true)
            else
              print_help(type: command, exit_status: 1)
            end
          when '--help', '-h'
            print_help(type: command)
          else
            print_help(type: command, exit_status: 1)
          end
        when '--help', '-h'
          print_help
        when "restart"
          self.exit_if_machine_not_running
          case subcommand
          when '--help', '-h'
            print_help(type: command)
          else
            restart_service(subcommand)
          end
        when "help"
            self.print_help
        else
          print_help(exit_status: 1)
        end
      end

      def print_help(config = {})
        config[:type] ||= 'default'
        config[:exit_status] ||= 0

        @env.ui.info(I18n.t("servicemanager.commands.help.#{config[:type]}"))
        exit config[:exit_status]
      end

      def service_running?(service)
        return kube_running? if KUBE_NAMES.include? service
        command = "systemctl status #{service}"
        with_target_vms(nil, {:single_target=>true}) do |machine|
          return machine.communicate.test(command)
        end
      end

      def service_status(service)
        return I18n.t('servicemanager.commands.status.status.running') if service_running?(service)
        I18n.t('servicemanager.commands.status.status.stopped')
      end

      def execute_status_display(service = nil)
        if service
          status = service_status(service)
          @env.ui.info("#{service} - #{status}")
        else
          @env.ui.info I18n.t('servicemanager.commands.status.nil')
          SUPPORTED_SERVICES.each do |service|
            status = service_status(service)
            @env.ui.info("#{service} - #{status}")
          end
        end
      end

      def kube_running?
        KUBE_SERVICES.each do |service|
          return false unless service_running?(service)
        end
        true
      end

      def running_services
        running_services = []
        SUPPORTED_SERVICES.each do |service|
          running_services << service if service_running?(service)
        end
        running_services
      end

      def print_all_provider_info(script_readable = false)
        running_services.each do |e|
          unless  script_readable
            # since we do not have feature to show the kube connection information
            @env.ui.info("\n#{e} env:") unless KUBE_NAMES.include? e
          end
          public_send("execute_#{e}_info", script_readable) unless KUBE_NAMES.include? e
        end
      end

      def execute_openshift_info(script_readable = false)
        @@OPENSHIFT_PORT = 8443
        if service_running?("openshift")
          # Find the guest IP
          guest_ip = self.find_machine_ip
          openshift_url = "https://#{guest_ip}:#@@OPENSHIFT_PORT"
          openshift_console_url = "#{openshift_url}/console"
          self.print_openshift_info(
            openshift_url,
            openshift_console_url,
            script_readable)
        else
          @env.ui.error I18n.t('servicemanager.commands.env.service_not_running',
                               name: 'OpenShift')
          exit 126
        end
      end

      def print_openshift_info(url, console_url, script_readable = false)
        if script_readable
          message = I18n.t('servicemanager.commands.env.openshift.script_readable',
                           openshift_url: url, openshift_console_url: console_url)
        else
          message = I18n.t('servicemanager.commands.env.openshift.default',
                           openshift_url: url, openshift_console_url: console_url)
        end

        @env.ui.info(message)
      end

      def find_machine_ip
        with_target_vms(nil, {:single_target=>true}) do |machine|
          # Find the guest IP
          command = "ip -o -4 addr show up |egrep -v ': docker|: lo' |tail -1 | awk '{print $4}' |cut -f1 -d\/"
          guest_ip = ""
          machine.communicate.execute(command) do |type, data|
            guest_ip << data.chomp if type == :stdout
          end
          return guest_ip
        end
      end

      def sha_id(file_data)
        Digest::SHA256.hexdigest file_data
      end

      def certs_present_and_valid?(path, machine)
        return false if Dir["#{path}/*"].empty?

        # check validity of certs
        Dir[path + "/*"].each do |f|
          guest_file_path = "#{DOCKER_PATH}/#{File.basename(f)}"
          guest_sha = machine.guest.capability(:sha_id, guest_file_path)
          return false if sha_id(File.read(f)) != guest_sha
        end

        true
      end

      def execute_docker_info(script_readable = false)
        # this execute the operations needed to print the docker env info
        with_target_vms(nil, {:single_target=>true}) do |machine|
          secrets_path = PluginUtil.host_docker_path(machine)
          # Hard Code the Docker port because it is fixed on the VM
          # This also makes it easier for the plugin to be cross-provider
          port = 2376

          # Verify valid certs and copy if invalid
          unless certs_present_and_valid?(secrets_path, machine)
            # Log the message prefixed by #
            PluginUtil.copy_certs_to_host(machine, secrets_path, @env.ui, true)
          end

          api_version = ""
          docker_api_version = "docker version --format '{{.Server.APIVersion}}'"
          unless machine.communicate.test(docker_api_version)
            # fix for issue #152: Fallback to older Docker version (< 1.9.1)
            docker_api_version.gsub!(/APIVersion/, 'ApiVersion')
          end

          machine.communicate.execute(docker_api_version) do |type, data|
            api_version << data.chomp if type ==:stdout
          end

          # display the information, irrespective of the copy operation
          self.print_docker_env_info(find_machine_ip, port, secrets_path, api_version, script_readable)
        end
      end

      def print_docker_env_info(guest_ip, port, secrets_path, api_version, script_readable)
        # Print configuration information for accessing the docker daemon
        if script_readable
          message = I18n.t('servicemanager.commands.env.docker.script_readable',
                           ip: guest_ip, port: port, path: secrets_path,
                           api_version: api_version)
          @env.ui.info(message)
        else
          if !OS.windows?
            message = I18n.t('servicemanager.commands.env.docker.non_windows',
                             ip: guest_ip, port: port, path: secrets_path,
                             api_version: api_version)
            @env.ui.info(message)
          elsif OS.windows_cygwin?
            # replace / with \ for path in Cygwin Windows - which uses export
            secrets_path = secrets_path.split('/').join('\\') + '\\'
            message = I18n.t('servicemanager.commands.env.docker.windows_cygwin',
                             ip: guest_ip, port: port, path: secrets_path,
                             api_version: api_version)
            @env.ui.info(message)
          else
            # replace / with \ for path in Windows
            secrets_path = secrets_path.split('/').join('\\') + '\\'
            message = I18n.t('servicemanager.commands.env.docker.windows',
                             ip: guest_ip, port: port, path: secrets_path,
                             api_version: api_version)
            # puts is used here to escape and render the back slashes in Windows path
            @env.ui.info(puts(message))
          end
        end
      end

      def print_vagrant_box_version(script_readable = false)
        # Prints the version of the vagrant box, parses /etc/os-release for version
        with_target_vms(nil, { single_target: true}) do |machine|
          command = "cat #{OS_RELEASE_FILE} | grep VARIANT"

          machine.communicate.execute(command) do |type, data|
            if type == :stderr
              @env.ui.error(data)
              exit 126
            end

            unless script_readable
              info = Hash[data.gsub('"', '').split("\n").map {|e| e.split("=") }]
              version = "#{info['VARIANT']} #{info['VARIANT_VERSION']}"
              @env.ui.info(version)
            else
              @env.ui.info(data.chomp)
            end
          end
        end
      end

      def restart_service(service)
        errors = []
        command = if SCCLI_SERVICES.include? service
                    # TODO : Handle the case where user wants to pass extra arguments
                    # to OpenShift service
                    "sccli #{service}"
                  else
                    "systemctl restart #{service}"
                   end

        with_target_vms(nil, single_target: true) do |machine|
          exit_code = machine.communicate.sudo(command) do |type, error|
            errors << error if type == :stderr
          end
          unless exit_code.zero?
            @env.ui.error errors.join("\n")
            exit exit_code
          end
          exit_code
        end
      end

    end
  end
end
