namespace :pg do
  namespace :check do

    #desc 'Ensure all postgresinator specific settings are set, and warn and exit if not.'
    task :settings => 'deployinator:load_settings' do
      require 'resolv'
      run_locally do
        {
          (File.dirname(__FILE__) + "/examples/config/deploy.rb") => 'config/deploy.rb',
          (File.dirname(__FILE__) + "/examples/config/deploy/staging.rb") => "config/deploy/#{fetch(:stage)}.rb"
        }.each do |abs, rel|
          Rake::Task['deployinator:settings'].invoke(abs, rel)
          Rake::Task['deployinator:settings'].reenable
        end
      end
      on roles(:db, :db_slave, :in => :parallel) do |host|
        unless host.properties.respond_to?(:postgres_port)
          fatal "#{host} does not have postgres_port set." and exit
        end
        unless host.properties.respond_to?(:ip)
          host.properties.set :ip, Resolv.getaddress(host.to_s)
        end
      end
      on roles(:db) do |host|
        unless host.properties.respond_to?(:postgres_container_name)
          host.properties.set :postgres_container_name, "#{fetch(:domain)}-postgres-master_#{host.properties.postgres_port}"
        end
      end
      on roles(:db_slave, :in => :parallel) do |host|
        unless host.properties.respond_to?(:postgres_container_name)
          host.properties.set :postgres_container_name, "#{fetch(:domain)}-postgres-slave_#{host.properties.postgres_port}"
        end
      end
      run_locally do
        unless roles(:db).length == 1
          fatal "You can't set more than one master! (set only one host in the :db role.)"
          fatal roles(:db)
          exit
        end
      end
    end
    before 'pg:setup', 'pg:check:settings'

    namespace :settings do
      desc 'Print example postgresinator specific settings for comparison.'
      task :print => 'deployinator:load_settings' do
        set :print_all, true
        Rake::Task['pg:check:settings'].invoke
      end

      task :database, [:database_name] do |t, args|
        run_locally do
          database_found = false
          fetch(:postgres_databases).each do |database|
            next unless database[:name] == args.database_name
            database_found = true
          end
          fatal "Database #{args.database_name} not found in the configuration" and exit unless database_found
        end
      end

      task :domain, [:domain] do |t, args|
        run_locally do
          unless roles(:db, :db_slave).select { |host| host.to_s == args.domain }.length == 1
            fatal "Server domain #{args.domain} not found in the configuration" and exit
          end
        end
      end

      task :postgres_uid_gid => 'deployinator:load_settings' do
        on roles(:db) do
          set :postgres_uid, -> {
            capture("docker", "run", "--rm", "--tty",
              "--entrypoint", "/usr/bin/id",
              fetch(:postgres_image_name), "-u", "postgres").strip
          }
          set :postgres_gid, -> {
            capture("docker", "run", "--rm", "--tty",
              "--entrypoint", "/usr/bin/id",
              fetch(:postgres_image_name), "-g", "postgres").strip
          }
        end
      end
    end

    task :file_permissions => ['pg:ensure_setup', 'postgresinator:deployment_user', 'postgresinator:webserver_user'] do
      on roles(:db, :db_slave, :in => :parallel) do |host|
        as "root" do
          execute "mkdir", "-p", fetch(:postgres_data_path),
            fetch(:postgres_socket_path), fetch(:postgres_config_path)
          ["#{fetch(:deploy_to)}/..", fetch(:deploy_to), shared_path].each do |dir|
            execute("chown", "#{fetch(:deployment_username)}:#{unix_user_get_gid(fetch(:webserver_username))}", dir.to_s)
            execute("chmod", "2750", dir.to_s)
          end
          # chown everything
          execute("chown", "-R", "#{fetch(:postgres_uid)}:#{fetch(:postgres_gid)}",
            fetch(:postgres_root_path))
          # chmod data_path
          execute "find", fetch(:postgres_data_path), "-type", "d",
            "-exec", "chmod", "2700", "{}", "+"
          execute "find", fetch(:postgres_data_path), "-type", "f",
            "-exec", "chmod", "0600", "{}", "+"
          # chmod everything but data_path
          execute "find", fetch(:postgres_root_path), "-type", "d",
            "-not", "-path", "\"#{fetch(:postgres_data_path)}\"",
            "-not", "-path", "\"#{fetch(:postgres_data_path)}/*\"",
            "-exec", "chmod", "2775", "{}", "+"
          execute "find", fetch(:postgres_root_path), "-type", "f",
            "-not", "-path", "\"#{fetch(:postgres_data_path)}\"",
            "-not", "-path", "\"#{fetch(:postgres_data_path)}/*\"",
            "-exec", "chmod", "0660", "{}", "+"
        end
      end
    end
    after 'pg:install_config_files', 'pg:check:file_permissions'

    task :firewall => ['pg:ensure_setup', 'postgresinator:deployment_user'] do
      on roles(:db, :db_slave, :in => :parallel) do |host|
        as "root" do
          if test "ufw", "status"
            success = test("ufw", "allow", "#{host.properties.postgres_port}/tcp")
            fatal "Error during opening UFW firewall" and exit unless success
          else
            warn "Uncomplicated Firewall does not appear to be installed, making no firewall action."
          end
        end
      end
    end

  end
end
