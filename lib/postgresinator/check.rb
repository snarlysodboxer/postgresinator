namespace :pg do
  namespace :check do

    desc 'Ensure all postgresinator specific settings are set, and warn and exit if not.'
    before 'pg:setup', :settings do
      require 'resolv' unless defined?(Resolv)
      {
        (File.dirname(__FILE__) + "/examples/config/deploy.rb") => 'config/deploy.rb',
        (File.dirname(__FILE__) + "/examples/config/deploy/staging.rb") => "config/deploy/#{fetch(:stage)}.rb"
      }.each do |abs, rel|
        Rake::Task['deployinator:settings'].invoke(abs, rel)
        Rake::Task['deployinator:settings'].reenable
      end
      on roles(:db, :db_slave) do |host|
        unless host.properties.respond_to?(:postgres_port)
          fatal "#{host} does not have postgres_port set." and exit
        end
        unless host.properties.respond_to?(:ip)
          host.properties.set :ip, Resolv.getaddress(host)
        end
      end
      on roles(:db) do |host|
        unless host.properties.respond_to?(:postgres_container_name)
          host.properties.set :postgres_container_name, "#{fetch(:domain)}-postgres-master_#{host.properties.postgres_port}"
        end
      end
      on roles(:db_slave) do |host|
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

    namespace :settings do
      desc 'Print example postgresinator specific settings for comparison.'
      task :print do
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
          fatal "Database #{args.domain} not found in the configuration" and exit unless database_found
        end
      end

      task :domain, [:domain] do |t, args|
        run_locally do
          fatal "Server domain #{args.domain} not found in the configuration" and exit unless roles(:db, :db_slave).include? args.domain
        end
      end
    end

    task :file_permissions => 'deployinator:deployment_user' do
      on roles(:db, :db_slave) do |host|
        as "root" do
          execute "mkdir", "-p", fetch(:postgres_data_path), fetch(:postgres_socket_path)
          execute("chown", "-R", "#{fetch(:postgres_uid)}:#{fetch(:postgres_gid)}",
            fetch(:postgres_config_path))
          execute("chown", "-R", "#{fetch(:postgres_uid)}:#{fetch(:postgres_gid)}",
            fetch(:postgres_socket_path))
          execute "find", fetch(:postgres_config_path), "-type", "d",
            "-exec", "chmod", "2775", "{}", "+"
          execute "find", fetch(:postgres_config_path), "-type", "f",
            "-exec", "chmod", "0660", "{}", "+"
        end
      end
    end

    task :firewalls => 'pg:ensure_setup' do
      on roles(:db, :db_slave) do |host|
        as "root" do
          if test "ufw", "status"
            fatal "Error during opening UFW firewall" and exit unless test("ufw", "allow", "#{host.properties.postgres_port}/tcp")
          else
            warn "Uncomplicated Firewall does not appear to be installed, making no firewall action."
          end
        end
      end
    end

  end
end
