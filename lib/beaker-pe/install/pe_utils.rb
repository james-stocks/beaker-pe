[ 'aio_defaults', 'pe_defaults', 'puppet_utils', 'windows_utils' ].each do |lib|
    require "beaker/dsl/install_utils/#{lib}"
end
require "beaker-answers"
require "timeout"
require "json"
module Beaker
  module DSL
    module InstallUtils
      #
      # This module contains methods to help installing/upgrading PE builds - including Higgs installs
      #
      # To mix this is into a class you need the following:
      # * a method *hosts* that yields any hosts implementing
      #   {Beaker::Host}'s interface to act upon.
      # * a method *options* that provides an options hash, see {Beaker::Options::OptionsHash}
      # * the module {Beaker::DSL::Roles} that provides access to the various hosts implementing
      #   {Beaker::Host}'s interface to act upon
      # * the module {Beaker::DSL::Wrappers} the provides convenience methods for {Beaker::DSL::Command} creation
      module PEUtils
        include AIODefaults
        include PEDefaults
        include PuppetUtils
        include WindowsUtils

        # Version of PE when we switched from legacy installer to MEEP.
        MEEP_CUTOVER_VERSION = '2016.2.0'

        # @!macro [new] common_opts
        #   @param [Hash{Symbol=>String}] opts Options to alter execution.
        #   @option opts [Boolean] :silent (false) Do not produce log output
        #   @option opts [Array<Fixnum>] :acceptable_exit_codes ([0]) An array
        #     (or range) of integer exit codes that should be considered
        #     acceptable.  An error will be thrown if the exit code does not
        #     match one of the values in this list.
        #   @option opts [Boolean] :accept_all_exit_codes (false) Consider all
        #     exit codes as passing.
        #   @option opts [Boolean] :dry_run (false) Do not actually execute any
        #     commands on the SUT
        #   @option opts [String] :stdin (nil) Input to be provided during command
        #     execution on the SUT.
        #   @option opts [Boolean] :pty (false) Execute this command in a pseudoterminal.
        #   @option opts [Boolean] :expect_connection_failure (false) Expect this command
        #     to result in a connection failure, reconnect and continue execution.
        #   @option opts [Hash{String=>String}] :environment ({}) These will be
        #     treated as extra environment variables that should be set before
        #     running the command.

        #Sort array of hosts so that it has the correct order for PE installation based upon each host's role
        #@param subset [Array<Host>] An array of hosts to sort, defaults to global 'hosts' object
        # @example
        #  h = sorted_hosts
        #
        # @note Order for installation should be
        #        First : master
        #        Second: database host (if not same as master)
        #        Third:  dashboard (if not same as master or database)
        #        Fourth: everything else
        #
        # @!visibility private
        def sorted_hosts subset = hosts
          special_nodes = []
          [master, database, dashboard].uniq.each do |host|
            special_nodes << host if host != nil && subset.include?(host)
          end
          real_agents = agents - special_nodes
          real_agents = real_agents.delete_if{ |host| !subset.include?(host) }
          special_nodes + real_agents
        end

        #Create the PE install command string based upon the host and options settings
        # @param [Host] host The host that PE is to be installed on
        #                    For UNIX machines using the full PE installer, the host object must have the 'pe_installer' field set correctly.
        # @param [Hash{Symbol=>String}] opts The options
        # @option opts [String]  :pe_ver Default PE version to install or upgrade to
        #                          (Otherwise uses individual hosts pe_ver)
        # @option opts [Boolean] :pe_debug (false) Should we run the installer in debug mode?
        # @example
        #      on host, "#{installer_cmd(host, opts)} -a #{host['working_dir']}/answers"
        # @api private
        def installer_cmd(host, opts)
          version = host['pe_ver'] || opts[:pe_ver]
          # Frictionless install didn't exist pre-3.2.0, so in that case we fall
          # through and do a regular install.
          if host['roles'].include? 'frictionless' and ! version_is_less(version, '3.2.0')
            # PE 3.4 introduced the ability to pass in config options to the bash script in the form
            # of <section>:<key>=<value>
            frictionless_install_opts = []
            if host.has_key?('frictionless_options') and !  version_is_less(version, '3.4.0')
              # since we have options to pass in, we need to tell the bash script
              host['frictionless_options'].each do |section, settings|
                settings.each do |key, value|
                  frictionless_install_opts << "#{section}:#{key}=#{value}"
                end
              end
            end

            pe_debug = host[:pe_debug] || opts[:pe_debug] ? ' -x' : ''
            if host['platform'] =~ /windows/ then
              "powershell -c \"cd #{host['working_dir']};[Net.ServicePointManager]::ServerCertificateValidationCallback = {\\$true};\\$webClient = New-Object System.Net.WebClient;\\$webClient.DownloadFile('https://#{master}:8140/packages/#{version}/install.ps1', '#{host['working_dir']}/install.ps1');#{host['working_dir']}/install.ps1 -verbose #{frictionless_install_opts.join(' ')}\""
            elsif host['platform'] =~ /aix/ then
              curl_opts = '--tlsv1 -O'
              "cd #{host['working_dir']} && curl #{curl_opts} https://#{master}:8140/packages/#{version}/install.bash && bash#{pe_debug} install.bash #{frictionless_install_opts.join(' ')}".strip
            else
              curl_opts = '--tlsv1 -kO'
              "cd #{host['working_dir']} && curl #{curl_opts} https://#{master}:8140/packages/#{version}/install.bash && bash#{pe_debug} install.bash #{frictionless_install_opts.join(' ')}".strip
            end
          elsif host['platform'] =~ /osx/
            version = host['pe_ver'] || opts[:pe_ver]
            pe_debug = host[:pe_debug] || opts[:pe_debug] ? ' -verboseR' : ''
            "cd #{host['working_dir']} && hdiutil attach #{host['dist']}.dmg && installer#{pe_debug} -pkg /Volumes/puppet-enterprise-#{version}/puppet-enterprise-installer-#{version}.pkg -target /"
          elsif host['platform'] =~ /eos/
            host.install_from_file("puppet-enterprise-#{version}-#{host['platform']}.swix")
          else
            pe_debug = host[:pe_debug] || opts[:pe_debug]  ? ' -D' : ''
            pe_cmd = "cd #{host['working_dir']}/#{host['dist']} && ./#{host['pe_installer']}#{pe_debug}"
            if ! version_is_less(host['pe_ver'], '2016.2.1')
              # -y option sets "assume yes" mode where yes or whatever default will be assumed
              pe_cmd += " -y"
            end

            # If there are no answer overrides, and we are doing an upgrade from 2016.2.0,
            # we can assume there will be a valid pe.conf in /etc that we can re-use.
            if opts[:answers].nil? && opts[:custom_answers].nil? && opts[:type] == :upgrade && !version_is_less(opts[:HOSTS][host.name][:pe_ver], '2016.2.0')
              "#{pe_cmd}"
            else
              "#{pe_cmd} #{host['pe_installer_conf_setting']}"
            end
          end
        end

        #Determine the PE package to download/upload on a mac host, download/upload that package onto the host.
        # Assumed file name format: puppet-enterprise-3.3.0-rc1-559-g97f0833-osx-10.9-x86_64.dmg.
        # @param [Host] host The mac host to download/upload and unpack PE onto
        # @param  [Hash{Symbol=>Symbol, String}] opts The options
        # @option opts [String] :pe_dir Default directory or URL to pull PE package from
        #                  (Otherwise uses individual hosts pe_dir)
        # @option opts [Boolean] :fetch_local_then_push_to_host determines whether
        #                 you use Beaker as the middleman for this (true), or curl the
        #                 file from the host (false; default behavior)
        # @api private
        def fetch_pe_on_mac(host, opts)
          path = host['pe_dir'] || opts[:pe_dir]
          local = File.directory?(path)
          filename = "#{host['dist']}"
          extension = ".dmg"
          if local
            if not File.exists?("#{path}/#{filename}#{extension}")
              raise "attempting installation on #{host}, #{path}/#{filename}#{extension} does not exist"
            end
            scp_to host, "#{path}/#{filename}#{extension}", "#{host['working_dir']}/#{filename}#{extension}"
          else
            if not link_exists?("#{path}/#{filename}#{extension}")
              raise "attempting installation on #{host}, #{path}/#{filename}#{extension} does not exist"
            end
            if opts[:fetch_local_then_push_to_host]
              fetch_and_push_pe(host, path, filename, extension)
            else
              on host, "cd #{host['working_dir']}; curl -O #{path}/#{filename}#{extension}"
            end
          end
        end

        #Determine the PE package to download/upload on a windows host, download/upload that package onto the host.
        #Assumed file name format: puppet-enterprise-3.3.0-rc1-559-g97f0833.msi
        # @param [Host] host The windows host to download/upload and unpack PE onto
        # @param  [Hash{Symbol=>Symbol, String}] opts The options
        # @option opts [String] :pe_dir Default directory or URL to pull PE package from
        #                  (Otherwise uses individual hosts pe_dir)
        # @option opts [String] :pe_ver_win Default PE version to install or upgrade to
        #                  (Otherwise uses individual hosts pe_ver)
        # @option opts [Boolean] :fetch_local_then_push_to_host determines whether
        #                 you use Beaker as the middleman for this (true), or curl the
        #                 file from the host (false; default behavior)
        # @api private
        def fetch_pe_on_windows(host, opts)
          path = host['pe_dir'] || opts[:pe_dir]
          local = File.directory?(path)
          version = host['pe_ver'] || opts[:pe_ver_win]
          filename = "#{host['dist']}"
          extension = ".msi"
          if local
            if not File.exists?("#{path}/#{filename}#{extension}")
              raise "attempting installation on #{host}, #{path}/#{filename}#{extension} does not exist"
            end
            scp_to host, "#{path}/#{filename}#{extension}", "#{host['working_dir']}/#{filename}#{extension}"
          else
            if not link_exists?("#{path}/#{filename}#{extension}")
              raise "attempting installation on #{host}, #{path}/#{filename}#{extension} does not exist"
            end
            if opts[:fetch_local_then_push_to_host]
              fetch_and_push_pe(host, path, filename, extension)
              on host, "cd #{host['working_dir']}; chmod 644 #{filename}#{extension}"
            elsif host.is_cygwin?
              on host, "cd #{host['working_dir']}; curl -O #{path}/#{filename}#{extension}"
            else
              on host, powershell("$webclient = New-Object System.Net.WebClient;  $webclient.DownloadFile('#{path}/#{filename}#{extension}','#{host['working_dir']}\\#{filename}#{extension}')")
            end
          end
        end

        #Determine the PE package to download/upload on a unix style host, download/upload that package onto the host
        #and unpack it.
        # @param [Host] host The unix style host to download/upload and unpack PE onto
        # @param  [Hash{Symbol=>Symbol, String}] opts The options
        # @option opts [String] :pe_dir Default directory or URL to pull PE package from
        #                  (Otherwise uses individual hosts pe_dir)
        # @option opts [Boolean] :fetch_local_then_push_to_host determines whether
        #                 you use Beaker as the middleman for this (true), or curl the
        #                 file from the host (false; default behavior)
        # @api private
        def fetch_pe_on_unix(host, opts)
          path = host['pe_dir'] || opts[:pe_dir]
          local = File.directory?(path)
          filename = "#{host['dist']}"
          if local
            extension = File.exists?("#{path}/#{filename}.tar.gz") ? ".tar.gz" : ".tar"
            if not File.exists?("#{path}/#{filename}#{extension}")
              raise "attempting installation on #{host}, #{path}/#{filename}#{extension} does not exist"
            end
            scp_to host, "#{path}/#{filename}#{extension}", "#{host['working_dir']}/#{filename}#{extension}"
            if extension =~ /gz/
              on host, "cd #{host['working_dir']}; gunzip #{filename}#{extension}"
            end
            if extension =~ /tar/
              on host, "cd #{host['working_dir']}; tar -xvf #{filename}.tar"
            end
          else
            if host['platform'] =~ /eos/
              extension = '.swix'
            else
              extension = link_exists?("#{path}/#{filename}.tar.gz") ? ".tar.gz" : ".tar"
            end
            if not link_exists?("#{path}/#{filename}#{extension}")
              raise "attempting installation on #{host}, #{path}/#{filename}#{extension} does not exist"
            end

            if host['platform'] =~ /eos/
              host.get_remote_file("#{path}/#{filename}#{extension}")
            else
              unpack = 'tar -xvf -'
              unpack = extension =~ /gz/ ? 'gunzip | ' + unpack  : unpack
              if opts[:fetch_local_then_push_to_host]
                fetch_and_push_pe(host, path, filename, extension)
                command_file_push = 'cat '
              else
                command_file_push = "curl #{path}/"
              end
              on host, "cd #{host['working_dir']}; #{command_file_push}#{filename}#{extension} | #{unpack}"

            end
          end
        end

        #Determine the PE package to download/upload per-host, download/upload that package onto the host
        #and unpack it.
        # @param [Array<Host>] hosts The hosts to download/upload and unpack PE onto
        # @param  [Hash{Symbol=>Symbol, String}] opts The options
        # @option opts [String] :pe_dir Default directory or URL to pull PE package from
        #                  (Otherwise uses individual hosts pe_dir)
        # @option opts [String] :pe_ver Default PE version to install or upgrade to
        #                  (Otherwise uses individual hosts pe_ver)
        # @option opts [String] :pe_ver_win Default PE version to install or upgrade to on Windows hosts
        #                  (Otherwise uses individual Windows hosts pe_ver)
        # @option opts [Boolean] :fetch_local_then_push_to_host determines whether
        #                 you use Beaker as the middleman for this (true), or curl the
        #                 file from the host (false; default behavior)
        # @api private
        def fetch_pe(hosts, opts)
          hosts.each do |host|
            # We install Puppet from the master for frictionless installs, so we don't need to *fetch* anything
            next if host['roles'].include?('frictionless') && (! version_is_less(opts[:pe_ver] || host['pe_ver'], '3.2.0'))

            if host['platform'] =~ /windows/
              fetch_pe_on_windows(host, opts)
            elsif host['platform'] =~ /osx/
              fetch_pe_on_mac(host, opts)
            else
              fetch_pe_on_unix(host, opts)
            end
          end
        end

        #Classify the master so that it can deploy frictionless packages for a given host.
        # @param [Host] host The host to install pacakges for
        # @api private
        def deploy_frictionless_to_master(host)
          klass = host['platform'].gsub(/-/, '_').gsub(/\./,'')
          if host['platform'] =~ /windows/
            if host['template'] =~ /i386/
              klass = "pe_repo::platform::windows_i386"
            else
              klass = "pe_repo::platform::windows_x86_64"
            end
          else
            klass = "pe_repo::platform::#{klass}"
          end
          if version_is_less(host['pe_ver'], '3.8')
            # use the old rake tasks
            on dashboard, "cd /opt/puppet/share/puppet-dashboard && /opt/puppet/bin/bundle exec /opt/puppet/bin/rake nodeclass:add[#{klass},skip]"
            on dashboard, "cd /opt/puppet/share/puppet-dashboard && /opt/puppet/bin/bundle exec /opt/puppet/bin/rake node:add[#{master},,,skip]"
            on dashboard, "cd /opt/puppet/share/puppet-dashboard && /opt/puppet/bin/bundle exec /opt/puppet/bin/rake node:addclass[#{master},#{klass}]"
            on master, puppet("agent -t"), :acceptable_exit_codes => [0,2]
          else
            # the new hotness
            begin
              require 'scooter'
            rescue LoadError => e
              @logger.notify('WARNING: gem scooter is required for frictionless installation post 3.8')
              raise e
            end
            dispatcher = Scooter::HttpDispatchers::ConsoleDispatcher.new(dashboard)

            # Check if we've already created a frictionless agent node group
            # to avoid errors creating the same node group when the beaker hosts file contains
            # multiple hosts with the same platform
            node_group = dispatcher.get_node_group_by_name('Beaker Frictionless Agent')
            if node_group.nil? || node_group.empty?
              node_group = {}
              node_group['name'] = "Beaker Frictionless Agent"
              # Pin the master to the node
              node_group['rule'] = [ "and",  [ '=', 'name', master.to_s ]]
              node_group['classes'] ||= {}
            end

            # add the pe_repo platform class
            node_group['classes'][klass] = {}

            dispatcher.create_new_node_group_model(node_group)
            on master, puppet("agent -t"), :acceptable_exit_codes => [0,2]
          end
        end

        #Perform a Puppet Enterprise upgrade or install
        # @param [Array<Host>] hosts The hosts to install or upgrade PE on
        # @param  [Hash{Symbol=>Symbol, String}] opts The options
        # @option opts [String] :pe_dir Default directory or URL to pull PE package from
        #                  (Otherwise uses individual hosts pe_dir)
        # @option opts [String] :pe_ver Default PE version to install or upgrade to
        #                  (Otherwise uses individual hosts pe_ver)
        # @option opts [String] :pe_ver_win Default PE version to install or upgrade to on Windows hosts
        #                  (Otherwise uses individual Windows hosts pe_ver)
        # @option opts [Symbol] :type (:install) One of :upgrade or :install
        # @option opts [Boolean] :set_console_password Should we set the PE console password in the answers file?  Used during upgrade only.
        # @option opts [Hash<String>] :answers Pre-set answers based upon ENV vars and defaults
        #                             (See {Beaker::Options::Presets.env_vars})
        # @option opts [Boolean] :fetch_local_then_push_to_host determines whether
        #                 you use Beaker as the middleman for this (true), or curl the
        #                 file from the host (false; default behavior)
        # @option opts [Boolean] :masterless Are we performing a masterless installation?
        #
        # @example
        #  do_install(hosts, {:type => :upgrade, :pe_dir => path, :pe_ver => version, :pe_ver_win =>  version_win})
        #
        # @note on windows, the +:ruby_arch+ host parameter can determine in addition
        # to other settings whether the 32 or 64bit install is used
        #
        # @note for puppet-agent install options, refer to
        #   {Beaker::DSL::InstallUtils::FOSSUtils#install_puppet_agent_pe_promoted_repo_on}
        #
        # @api private
        #
        def do_install hosts, opts = {}
          masterless = opts[:masterless]
          opts[:type] = opts[:type] || :install
          unless masterless
            pre30database = version_is_less(opts[:pe_ver] || database['pe_ver'], '3.0')
            pre30master = version_is_less(opts[:pe_ver] || master['pe_ver'], '3.0')
          end

          pe_versions = ( [] << opts['pe_ver'] << hosts.map{ |host| host['pe_ver'] } ).flatten.compact
          agent_only_check_needed = version_is_less('3.99', max_version(pe_versions, '3.8'))
          if agent_only_check_needed
            hosts_agent_only, hosts_not_agent_only = create_agent_specified_arrays(hosts)
          else
            hosts_agent_only, hosts_not_agent_only = [], hosts.dup
          end

          # On July 8th, 2016, the GPG key used to sign repos inside PE tarballs
          # expired. Add a temporary, extended key to the host first so that it
          # can still install those old PE tarballs.
          add_extended_gpg_key_to_hosts(hosts, opts)

          # Set PE distribution for all the hosts, create working dir
          use_all_tar = ENV['PE_USE_ALL_TAR'] == 'true'
          hosts.each do |host|
            next if agent_only_check_needed && hosts_agent_only.include?(host)
            host['pe_installer'] ||= 'puppet-enterprise-installer'
            if host['platform'] !~ /windows|osx/
              platform = use_all_tar ? 'all' : host['platform']
              version = host['pe_ver'] || opts[:pe_ver]
              host['dist'] = "puppet-enterprise-#{version}-#{platform}"
            elsif host['platform'] =~ /osx/
              version = host['pe_ver'] || opts[:pe_ver]
              host['dist'] = "puppet-enterprise-#{version}-#{host['platform']}"
            elsif host['platform'] =~ /windows/
              version = host[:pe_ver] || opts['pe_ver_win']
              is_config_32 = true == (host['ruby_arch'] == 'x86') || host['install_32'] || opts['install_32']
              should_install_64bit = !(version_is_less(version, '3.4')) && host.is_x86_64? && !is_config_32
              #only install 64bit builds if
              # - we are on pe version 3.4+
              # - we do not have install_32 set on host
              # - we do not have install_32 set globally
              if !(version_is_less(version, '3.99'))
                if should_install_64bit
                  host['dist'] = "puppet-agent-#{version}-x64"
                else
                  host['dist'] = "puppet-agent-#{version}-x86"
                end
              elsif should_install_64bit
                host['dist'] = "puppet-enterprise-#{version}-x64"
              else
                host['dist'] = "puppet-enterprise-#{version}"
              end
            end
            host['working_dir'] = host.tmpdir(Time.new.strftime("%Y-%m-%d_%H.%M.%S"))
          end

          fetch_pe(hosts_not_agent_only, opts)

          install_hosts = hosts.dup
          unless masterless
            # If we're installing a database version less than 3.0, ignore the database host
            install_hosts.delete(database) if pre30database and database != master and database != dashboard
          end

          install_hosts.each do |host|
            #windows agents from 4.0 -> 2016.1.2 were only installable via the aio method
            is_windows_msi_and_aio = (host['platform'] =~ /windows/ && (version_is_less(host['pe_ver'], '2016.3.0') && !version_is_less(host['pe_ver'], '3.99')))

            if agent_only_check_needed && hosts_agent_only.include?(host) || is_windows_msi_and_aio
              host['type'] = 'aio'
              install_puppet_agent_pe_promoted_repo_on(host, { :puppet_agent_version => host[:puppet_agent_version] || opts[:puppet_agent_version],
                                                               :puppet_agent_sha => host[:puppet_agent_sha] || opts[:puppet_agent_sha],
                                                               :pe_ver => host[:pe_ver] || opts[:pe_ver],
                                                               :puppet_collection => host[:puppet_collection] || opts[:puppet_collection] })
              # 1 since no certificate found and waitforcert disabled
              acceptable_exit_codes = [0, 1]
              acceptable_exit_codes << 2 if opts[:type] == :upgrade
              setup_defaults_and_config_helper_on(host, master, acceptable_exit_codes)
            #Windows allows frictionless installs starting with PE Davis, if frictionless we need to skip this step
            elsif (host['platform'] =~ /windows/ && !(host['roles'].include?('frictionless')))
              opts = { :debug => host[:pe_debug] || opts[:pe_debug] }
              msi_path = "#{host['working_dir']}\\#{host['dist']}.msi"
              install_msi_on(host, msi_path, {}, opts)

              # 1 since no certificate found and waitforcert disabled
              acceptable_exit_codes = 1
              if masterless
                configure_type_defaults_on(host)
                on host, puppet_agent('-t'), :acceptable_exit_codes => acceptable_exit_codes
              else
                setup_defaults_and_config_helper_on(host, master, acceptable_exit_codes)
              end
            else
              # We only need answers if we're using the classic installer
              version = host['pe_ver'] || opts[:pe_ver]
              if host['roles'].include?('frictionless') &&  (! version_is_less(version, '3.2.0'))
                # If We're *not* running the classic installer, we want
                # to make sure the master has packages for us.
                if host['platform'] != master['platform'] # only need to do this if platform differs
                  deploy_frictionless_to_master(host)
                end
                on host, installer_cmd(host, opts)
                configure_type_defaults_on(host)
              elsif host['platform'] =~ /osx|eos/
                # If we're not frictionless, we need to run the OSX special-case
                on host, installer_cmd(host, opts)
                acceptable_codes = host['platform'] =~ /osx/ ? [1] : [0, 1]
                setup_defaults_and_config_helper_on(host, master, acceptable_codes)
              else
                prepare_host_installer_options(host)
                generate_installer_conf_file_for(host, hosts, opts)
                on host, installer_cmd(host, opts)
                configure_type_defaults_on(host)
              end
            end
            # On each agent, we ensure the certificate is signed
            if !masterless
              if [master, database, dashboard].include?(host) && use_meep?(host['pe_ver'])
                # This step is not necessary for the core pe nodes when using meep
              else
                step "Sign certificate for #{host}" do
                  sign_certificate_for(host)
                end
              end
            end
            # then shut down the agent
            step "Shutting down agent for #{host}" do
              stop_agent_on(host)
            end
          end

          unless masterless
            # Wait for PuppetDB to be totally up and running (post 3.0 version of pe only)
            sleep_until_puppetdb_started(database) unless pre30database

            step "First puppet agent run" do
              # Run the agent once to ensure everything is in the dashboard
              install_hosts.each do |host|
                on host, puppet_agent('-t'), :acceptable_exit_codes => [0,2]

                # Workaround for PE-1105 when deploying 3.0.0
                # The installer did not respect our database host answers in 3.0.0,
                # and would cause puppetdb to be bounced by the agent run. By sleeping
                # again here, we ensure that if that bounce happens during an upgrade
                # test we won't fail early in the install process.
                if host == database && ! pre30database
                  sleep_until_puppetdb_started(database)
                  check_puppetdb_status_endpoint(database)
                end
                if host == dashboard
                  check_console_status_endpoint(host)
                end
                #Workaround for windows frictionless install, see BKR-943 for the reason
                if (host['platform'] =~ /windows/) and (host['roles'].include? 'frictionless')
                  client_datadir = host.puppet['client_datadir']
                  on(host , puppet("resource file \"#{client_datadir}\" ensure=absent force=true"))
                end
              end
            end

            install_hosts.each do |host|
              wait_for_host_in_dashboard(host)
            end

            # only appropriate for pre-3.9 builds
            if version_is_less(master[:pe_ver], '3.99')
              if pre30master
                task = 'nodegroup:add_all_nodes group=default'
              else
                task = 'defaultgroup:ensure_default_group'
              end
              on dashboard, "/opt/puppet/bin/rake -sf /opt/puppet/share/puppet-dashboard/Rakefile #{task} RAILS_ENV=production"
            end

            step "Final puppet agent run" do
              # Now that all hosts are in the dashbaord, run puppet one more
              # time to configure mcollective
              install_hosts.each do |host|
                on host, puppet_agent('-t'), :acceptable_exit_codes => [0,2]
                # To work around PE-14318 if we just ran puppet agent on the
                # database node we will need to wait until puppetdb is up and
                # running before continuing
                if host == database && ! pre30database
                  sleep_until_puppetdb_started(database)
                  check_puppetdb_status_endpoint(database)
                end
                if host == dashboard
                  check_console_status_endpoint(host)
                end
              end
            end
          end
        end

        # True if version is greater than or equal to MEEP_CUTOVER_VERSION (2016.2.0)
        def use_meep?(version)
          !version_is_less(version, MEEP_CUTOVER_VERSION)
        end

        # On July 8th, 2016, the gpg key that was shipped and used to sign repos in
        # PE tarballs expired. This affects all PE version earlier then 3.8.5, and
        # versions between 2015.2 to 2016.1.2.
        #
        # PE 3.8.5 and 2016.1.2 shipped with a version of the key that had it's
        # expiration date extended by 6 months (to Janurary 2017).
        def add_extended_gpg_key_to_hosts(hosts, opts)
          hosts.each do |host|
            # RPM based platforms do not seem to be effected by an expired GPG key,
            # while deb based platforms are failing.
            if host['platform'] =~ /debian|ubuntu/
              host_ver = host['pe_ver'] || opts['pe_ver']

              if version_is_less(host_ver, '3.8.5') || (!version_is_less(host_ver, '2015.2.0') && version_is_less(host_ver, '2016.1.2'))
                on(host, 'curl http://apt.puppetlabs.com/DEB-GPG-KEY-puppetlabs | apt-key add -')
              end
            end
          end
        end

        # Set installer options on the passed *host* according to current
        # version.
        #
        # Sets:
        #   * 'pe_installer_conf_file'
        #   * 'pe_installer_conf_setting'
        #
        # @param [Beaker::Host] host The host object to configure
        # @return [Beaker::Host] The same host object passed in
        def prepare_host_installer_options(host)
          if use_meep?(host['pe_ver'])
            conf_file = "#{host['working_dir']}/pe.conf"
            host['pe_installer_conf_file'] = conf_file
            host['pe_installer_conf_setting'] = "-c #{conf_file}"
          else
            conf_file = "#{host['working_dir']}/answers"
            host['pe_installer_conf_file'] = conf_file
            host['pe_installer_conf_setting'] = "-a #{conf_file}"
          end
          host
        end

        # Adds in settings needed by BeakerAnswers:
        #
        # * :format => :bash or :hiera depending on which legacy or meep format we need
        # * :include_legacy_database_defaults => true or false.  True
        #   indicates that we are upgrading from a legacy version and
        #   BeakerAnswers should include the database defaults for user
        #   which were set for the legacy install.
        #
        # @param [Beaker::Host] host that we are generating answers for
        # @param [Hash] opts The Beaker options hash
        # @return [Hash] a dup of the opts hash with additional settings for BeakerAnswers
        def setup_beaker_answers_opts(host, opts)
          beaker_answers_opts = use_meep?(host['pe_ver']) ?
            { :format => :hiera } :
            { :format => :bash }

          beaker_answers_opts[:include_legacy_database_defaults] =
            opts[:type] == :upgrade && !use_meep?(host['previous_pe_ver'])

          opts.merge(beaker_answers_opts)
        end

        # Generates a Beaker Answers object for the passed *host* and creates
        # the answer or pe.conf configuration file on the *host* needed for
        # installation.
        #
        # Expects the host['pe_installer_conf_file'] to have been set, which is
        # where the configuration will be written to, and will run MEEP or legacy
        # depending on host[:pe_ver]
        #
        # @param [Beaker::Host] host The host to create a configuration file on
        # @param [Array<Beaker::Host]> hosts All of the hosts to be configured
        # @param [Hash] opts The Beaker options hash
        # @return [BeakerAnswers::Answers] the generated answers object
        def generate_installer_conf_file_for(host, hosts, opts)
          beaker_answers_opts = setup_beaker_answers_opts(host, opts)
          answers = BeakerAnswers::Answers.create(
            opts[:pe_ver] || host['pe_ver'], hosts, beaker_answers_opts
          )
          configuration = answers.installer_configuration_string(host)

          step "Generate the #{host['pe_installer_conf_file']} on #{host}" do
            logger.debug(configuration)
            create_remote_file(host, host['pe_installer_conf_file'], configuration)
          end

          answers
        end

        # Builds the agent_only and not_agent_only arrays needed for installation.
        #
        # @param [Array<Host>]          hosts hosts to split up into the arrays
        #
        # @note should only be called against versions 4.0+, as this method
        #   assumes AIO packages will be required.
        #
        # @note agent_only hosts with the :pe_ver setting < 4.0 will not be
        #   included in the agent_only array, as AIO install can only happen
        #   in versions > 4.0
        #
        # @api private
        # @return [Array<Host>, Array<Host>]
        #   the array of hosts to do an agent_only install on and
        #   the array of hosts to do our usual install methods on
        def create_agent_specified_arrays(hosts)
          hosts_agent_only = []
          hosts_not_agent_only = []
          non_agent_only_roles = %w(master database dashboard console frictionless)
          hosts.each do |host|
            if host['roles'].none? {|role| non_agent_only_roles.include?(role) }
              if !aio_version?(host)
                hosts_not_agent_only << host
              else
                hosts_agent_only << host
              end
            else
              hosts_not_agent_only << host
            end
          end
          return hosts_agent_only, hosts_not_agent_only
        end

        # Helper for setting up pe_defaults & setting up the cert on the host
        # @param [Host] host                            host to setup
        # @param [Host] master                          the master host, for setting up the relationship
        # @param [Array<Fixnum>] acceptable_exit_codes  The exit codes that we want to ignore
        #
        # @return nil
        # @api private
        def setup_defaults_and_config_helper_on(host, master, acceptable_exit_codes=nil)
          configure_type_defaults_on(host)
          #set the certname and master
          on host, puppet("config set server #{master}")
          on host, puppet("config set certname #{host}")
          #run once to request cert
          on host, puppet_agent('-t'), :acceptable_exit_codes => acceptable_exit_codes
        end

        #Install PE based on global hosts with global options
        #@see #install_pe_on
        def install_pe
          install_pe_on(hosts, options)
        end

        def check_puppetdb_status_endpoint(host)
          if version_is_less(host['pe_ver'], '2016.1.0')
            return true
          end
          Timeout.timeout(60) do
            match = nil
            while not match
              output = on(host, "curl -s http://localhost:8080/pdb/meta/v1/version", :accept_all_exit_codes => true)
              match = output.stdout =~ /version.*\d+\.\d+\.\d+/
              sleep 1
            end
          end
        rescue Timeout::Error
          fail_test "PuppetDB took too long to start"
        end

        # Checks Console Status Endpoint, failing the test if the
        # endpoints don't report a running state.
        #
        # @param [Host] host Host to check status on
        #
        # @note Uses the global option's :pe_console_status_attempts
        #   value to determine how many times it's going to retry the
        #   check with fibonacci back offs.
        #
        # @return nil
        def check_console_status_endpoint(host)
          return true if version_is_less(host['pe_ver'], '2015.2.0')

          attempts_limit = options[:pe_console_status_attempts] || 9
          step 'Check Console Status Endpoint' do
            match = repeat_fibonacci_style_for(attempts_limit) do
              output = on(host, "curl -s -k https://localhost:4433/status/v1/services --cert /etc/puppetlabs/puppet/ssl/certs/#{host}.pem --key /etc/puppetlabs/puppet/ssl/private_keys/#{host}.pem --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem", :accept_all_exit_codes => true)
              begin
                output = JSON.parse(output.stdout)
                match = output['classifier-service']['state'] == 'running'
                match = match && output['rbac-service']['state'] == 'running'
                match && output['activity-service']['state'] == 'running'
              rescue JSON::ParserError
                false
              end
            end
            fail_test 'Console services took too long to start' if !match
          end
        end

        #Install PE based upon host configuration and options
        #
        # @param [Host, Array<Host>] install_hosts    One or more hosts to act upon
        # @!macro common_opts
        # @option opts [Boolean] :masterless Are we performing a masterless installation?
        # @option opts [String] :puppet_agent_version  Version of puppet-agent to install. Required for PE agent
        #                                 only hosts on 4.0+
        # @option opts [String] :puppet_agent_sha The sha of puppet-agent to install, defaults to puppet_agent_version.
        #                                 Required for PE agent only hosts on 4.0+
        # @option opts [String] :pe_ver   The version of PE (will also use host['pe_ver']), defaults to '4.0'
        # @option opts [String] :puppet_collection   The puppet collection for puppet-agent install.
        #
        # @example
        #  install_pe_on(hosts, {})
        #
        # @note Either pe_ver and pe_dir should be set in the ENV or each host should have pe_ver and pe_dir set individually.
        #       Install file names are assumed to be of the format puppet-enterprise-VERSION-PLATFORM.(tar)|(tar.gz)
        #       for Unix like systems and puppet-enterprise-VERSION.msi for Windows systems.
        #
        # @note For further installation parameters (such as puppet-agent install)
        #   options, refer to {#do_install} documentation
        #
        def install_pe_on(install_hosts, opts)
          confine_block(:to, {}, install_hosts) do
            sorted_hosts.each do |host|
              #process the version files if necessary
              host['pe_dir'] ||= opts[:pe_dir]
              if host['platform'] =~ /windows/
                # we don't need the pe_version if:
                # * master pe_ver > 4.0
                if not (!opts[:masterless] && master[:pe_ver] && !version_is_less(master[:pe_ver], '3.99'))
                  host['pe_ver'] ||= Beaker::Options::PEVersionScraper.load_pe_version(host[:pe_dir] || opts[:pe_dir], opts[:pe_version_file_win])
                else
                  # inherit the master's version
                  host['pe_ver'] ||= master[:pe_ver]
                end
              else
                host['pe_ver'] ||= Beaker::Options::PEVersionScraper.load_pe_version(host[:pe_dir] || opts[:pe_dir], opts[:pe_version_file])
              end
            end
            do_install sorted_hosts, opts
          end
        end

        #Upgrade PE based upon global host configuration and global options
        #@see #upgrade_pe_on
        def upgrade_pe path=nil
          upgrade_pe_on(hosts, options, path)
        end

        #Upgrade PE based upon host configuration and options
        # @param [Host, Array<Host>]  upgrade_hosts   One or more hosts to act upon
        # @!macro common_opts
        # @param [String] path A path (either local directory or a URL to a listing of PE builds).
        #                      Will contain a LATEST file indicating the latest build to install.
        #                      This is ignored if a pe_upgrade_ver and pe_upgrade_dir are specified
        #                      in the host configuration file.
        # @example
        #  upgrade_pe_on(agents, {}, "http://neptune.puppetlabs.lan/3.0/ci-ready/")
        #
        # @note Install file names are assumed to be of the format puppet-enterprise-VERSION-PLATFORM.(tar)|(tar.gz)
        #       for Unix like systems and puppet-enterprise-VERSION.msi for Windows systems.
        def upgrade_pe_on upgrade_hosts, opts, path=nil
          confine_block(:to, {}, upgrade_hosts) do
            set_console_password = false
            # if we are upgrading from something lower than 3.4 then we need to set the pe console password
            if (dashboard[:pe_ver] ? version_is_less(dashboard[:pe_ver], "3.4.0") : true)
              set_console_password = true
            end
            # get new version information
            hosts.each do |host|
              prep_host_for_upgrade(host, opts, path)
            end
            do_install(sorted_hosts, opts.merge({:type => :upgrade, :set_console_password => set_console_password}))
            opts['upgrade'] = true
          end
        end

        #Prep a host object for upgrade; used inside upgrade_pe_on
        # @param [Host] host A single host object to prepare for upgrade
        # !macro common_opts
        # @param [String] path A path (either local directory or a URL to a listing of PE builds).
        #                      Will contain a LATEST file indicating the latest build to install.
        #                      This is ignored if a pe_upgrade_ver and pe_upgrade_dir are specified
        #                      in the host configuration file.
        # @example
        #  prep_host_for_upgrade(master, {}, "http://neptune.puppetlabs.lan/3.0/ci-ready/")
        def prep_host_for_upgrade(host, opts={}, path='')
          host['pe_dir'] = host['pe_upgrade_dir'] || path
          host['previous_pe_ver'] = host['pe_ver']
          if host['platform'] =~ /windows/
            host['pe_ver'] = host['pe_upgrade_ver'] || opts['pe_upgrade_ver'] ||
              Options::PEVersionScraper.load_pe_version(host['pe_dir'], opts[:pe_version_file_win])
          else
            host['pe_ver'] = host['pe_upgrade_ver'] || opts['pe_upgrade_ver'] ||
              Options::PEVersionScraper.load_pe_version(host['pe_dir'], opts[:pe_version_file])
          end
          if version_is_less(host['pe_ver'], '3.0')
            host['pe_installer'] ||= 'puppet-enterprise-upgrader'
          end
        end

        #Create the Higgs install command string based upon the host and options settings.  Installation command will be run as a
        #background process.  The output of the command will be stored in the provided host['higgs_file'].
        # @param [Host] host The host that Higgs is to be installed on
        #                    The host object must have the 'working_dir', 'dist' and 'pe_installer' field set correctly.
        # @api private
        def higgs_installer_cmd host
          higgs_answer = use_meep?(host['pe_ver']) ? '1' : 'Y'
          "cd #{host['working_dir']}/#{host['dist']} ; nohup ./#{host['pe_installer']} <<<#{higgs_answer} > #{host['higgs_file']} 2>&1 &"
        end

        #Perform a Puppet Enterprise Higgs install up until web browser interaction is required, runs on linux hosts only.
        # @param [Host] host The host to install higgs on
        # @param  [Hash{Symbol=>Symbol, String}] opts The options
        # @option opts [String] :pe_dir Default directory or URL to pull PE package from
        #                  (Otherwise uses individual hosts pe_dir)
        # @option opts [String] :pe_ver Default PE version to install
        #                  (Otherwise uses individual hosts pe_ver)
        # @option opts [Boolean] :fetch_local_then_push_to_host determines whether
        #                 you use Beaker as the middleman for this (true), or curl the
        #                 file from the host (false; default behavior)
        # @raise [StandardError] When installation times out
        #
        # @example
        #  do_higgs_install(master, {:pe_dir => path, :pe_ver => version})
        #
        # @api private
        #
        def do_higgs_install host, opts
          use_all_tar = ENV['PE_USE_ALL_TAR'] == 'true'
          platform = use_all_tar ? 'all' : host['platform']
          version = host['pe_ver'] || opts[:pe_ver]
          host['dist'] = "puppet-enterprise-#{version}-#{platform}"

          use_all_tar = ENV['PE_USE_ALL_TAR'] == 'true'
          host['pe_installer'] ||= 'puppet-enterprise-installer'
          host['working_dir'] = host.tmpdir(Time.new.strftime("%Y-%m-%d_%H.%M.%S"))

          fetch_pe([host], opts)

          host['higgs_file'] = "higgs_#{File.basename(host['working_dir'])}.log"

          prepare_host_installer_options(host)
          on host, higgs_installer_cmd(host), opts

          #wait for output to host['higgs_file']
          #we're all done when we find this line in the PE installation log
          if version_is_less(options[:pe_ver] || host['pe_ver'], '2016.3')
            higgs_re = /Please\s+go\s+to\s+https:\/\/.*\s+in\s+your\s+browser\s+to\s+continue\s+installation/m
          else
            higgs_re = /o\s+to\s+https:\/\/.*\s+in\s+your\s+browser\s+to\s+continue\s+installation/m
          end
          res = Result.new(host, 'tmp cmd')
          tries = 10
          attempts = 0
          prev_sleep = 0
          cur_sleep = 1
          while (res.stdout !~ higgs_re) and (attempts < tries)
            res = on host, "cd #{host['working_dir']}/#{host['dist']} && cat #{host['higgs_file']}", :accept_all_exit_codes => true
            attempts += 1
            sleep( cur_sleep )
            prev_sleep = cur_sleep
            cur_sleep = cur_sleep + prev_sleep
          end

          if attempts >= tries
            raise "Failed to kick off PE (Higgs) web installation"
          end
        end

        #Install Higgs up till the point where you need to continue installation in a web browser, defaults to execution
        #on the master node.
        #@param [Host] higgs_host The host to install Higgs on (supported on linux platform only)
        # @example
        #  install_higgs
        #
        # @note Either pe_ver and pe_dir should be set in the ENV or each host should have pe_ver and pe_dir set individually.
        #       Install file names are assumed to be of the format puppet-enterprise-VERSION-PLATFORM.(tar)|(tar.gz).
        #
        def install_higgs( higgs_host = master )
          #process the version files if necessary
          master['pe_dir'] ||= options[:pe_dir]
          master['pe_ver'] = master['pe_ver'] || options['pe_ver'] ||
            Beaker::Options::PEVersionScraper.load_pe_version(master[:pe_dir] || options[:pe_dir], options[:pe_version_file])
          if higgs_host['platform'] =~ /osx|windows/
            raise "Attempting higgs installation on host #{higgs_host.name} with unsupported platform #{higgs_host['platform']}"
          end
          #send in the global options hash
          do_higgs_install higgs_host, options
        end

        # Grabs the pe file from a remote host to the machine running Beaker, then
        # scp's the file out to the host.
        #
        # @param [Host] host The host to install on
        # @param [String] path path to the install file
        # @param [String] filename the filename of the pe file (without the extension)
        # @param [String] extension the extension of the pe file
        # @param [String] local_dir the directory to store the pe file in on
        #                   the Beaker-running-machine
        #
        # @api private
        # @return nil
        def fetch_and_push_pe(host, path, filename, extension, local_dir='tmp/pe')
          fetch_http_file("#{path}", "#{filename}#{extension}", local_dir)
          scp_to host, "#{local_dir}/#{filename}#{extension}", host['working_dir']
        end

      end
    end
  end
end
