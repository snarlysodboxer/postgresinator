require 'resolv'
require 'hashie'

namespace :config do

  task :load_settings do
    cluster = Hashie::Mash.new(PostgresCluster.settings)
    cluster.ssh_user            = ENV["USER"]
    cluster.servers.each do |server|
      server.ip = Resolv.getaddress(server.domain)
      server.master_or_slave    = server.master ? "master" : "slave"
      server.master_domain      = cluster.servers.collect { |s| s.domain if s.master }.first
      server.master_port        = cluster.servers.collect { |s| s.port if s.master }.first
      server.container_name     = "#{server.master_domain}-postgres-#{server.port}-#{server.master_or_slave}"
      server.data_path          = "/#{server.container_name}-data"
      server.conf_path          = "/#{server.container_name}-conf"
      server.docker_run_command = [
        "--detach", "--tty", "--user", "postgres",
        "--name", server.container_name,
        "--volume", "#{server.data_path}:#{cluster.image.data_path}:rw",
        "--volume", "#{server.conf_path}:#{cluster.image.conf_path}:rw",
        "--expose", "5432",
        "--publish", "0.0.0.0:#{server.port}:5432",
        cluster.image.name
      ]
      if server.master
        cluster.docker_init_command = [
          #"--interactive", "--rm", "--user", "root",
          "--rm", "--user", "root",
          "--volume", "#{server.data_path}:/postgresql-data:rw",
          "--entrypoint", "/usr/bin/rsync",
          cluster.image.name, "-ahP", "#{cluster.image.data_path}/", "/postgresql-data/"
        ]
      end
    end
    @cluster = cluster
  end

  task :ensure_cluster_data_uniqueness => :load_settings do
    cluster = @cluster
    run_locally do
      names = cluster.servers.collect { |s| s.container_name }
      fatal "The container names in this cluster are not unique" and raise unless names == names.uniq

      masters = cluster.servers.collect { |s| s.domain if s.master }
      fatal "You can't set more than one master" and raise unless masters.compact.length == 1
    end
  end

  desc 'Write example config files'
  task :write_examples do
    run_locally do
      execute "mkdir -p ./templates"

      # example postgresinator.rb
      config = File.read(File.dirname(__FILE__) + '/examples/postgresinator_example.rb')
      File.open('./postgresinator_example.rb', 'w') { |f| f.write(config) }
      info "Wrote './postgresinator_example.rb'"
      info "Run `mv postgresinator_example.rb postgrestinator.rb` or diff those files and add the needed lines."

      # example postgresql.conf.erb
      config = File.read(File.dirname(__FILE__) + '/examples/postgresql_example.conf.erb')
      File.open('./templates/postgresql_example.conf.erb', 'w') { |f| f.write(config) }
      info "Wrote './templates/postgres_example.conf.erb'"
      info "Run `mv templates/postgresql_example.conf.erb templates/postgresql.conf.erb` or diff those files and add the needed lines."

      # example pg_hba.conf.erb
      config = File.read(File.dirname(__FILE__) + '/examples/pg_hba_example.conf.erb')
      File.open('./templates/pg_hba_example.conf.erb', 'w') { |f| f.write(config) }
      info "Wrote './templates/pg_hba_example.conf.erb'"
      info "Run `mv templates/pg_hba_example.conf.erb templates/pg_hba.conf.erb` or diff those files and add the needed lines."

      # example recovery.conf.erb
      config = File.read(File.dirname(__FILE__) + '/examples/recovery_example.conf.erb')
      File.open('./templates/recovery_example.conf.erb', 'w') { |f| f.write(config) }
      info "Wrote './templates/recovery_example.conf.erb'"
      info "Run `mv templates/recovery_example.conf.erb templates/recovery.conf.erb` or diff those files and add the needed lines."
    end
  end

  task :config_file_not_found, [:config_file] do |t, args|
    cluster = @cluster
    run_locally do
      config_file_found = false
      cluster.image.config_files.each do |config_file|
        next unless config_file == args.config_file
        config_file_found = true
      end
      fatal "Config file #{args.config_file} not found in the configuration" and raise unless config_file_found
      config_template_found = test("ls", "-A", "templates/#{args.config_file}.erb")
      fatal "Config template file templates/#{args.config_file}.erb not found locally" and raise unless config_template_found
    end
  end

  task :database_not_found, [:database_name] do |t, args|
    cluster = @cluster
    run_locally do
      database_found = false
      cluster.databases.each do |database|
        next unless database.name == args.database_name
        database_found = true
      end
      fatal "Database #{args.domain} not found in the configuration" and raise unless database_found
    end
  end

  task :domain_not_found, [:domain] do |t, args|
    cluster = @cluster
    run_locally do
      domain_found = false
      cluster.servers.each do |server|
        next unless server.domain == args.domain
        domain_found = true
      end
      fatal "Server domain #{args.domain} not found in the configuration" and raise unless domain_found
    end
  end

  task :role_not_found, [:role_name] do |t, args|
    cluster = @cluster
    run_locally do
      role_found = false
      cluster.databases.each do |database|
        next unless database.role == args.role_name
        role_found = true
      end
      fatal "Role #{args.role_name} not found in the configuration" and raise unless role_found
    end
  end

end
