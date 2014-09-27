require 'erb'
require 'hashie'
require 'resolv'

require './postgresinator.rb'

## NOTES:
# tasks without 'desc' description lines are for manual debugging of this
#   deployment code.
# postgrestinator does not currently support more than one master or slave per domain for a particular cluster configuration file.
#
# we've choosen to only pass strings (if anything) to tasks. this allows tasks to be
#   debugged indivudually. only private methods take ruby objects.

namespace :pg do

  task :load_settings do
    cluster = Hashie::Mash.new(PostgresCluster.settings)
    cluster.ssh_user            = ENV["USER"]
    cluster.servers.each do |server|
      server.ip = Resolv.getaddress(server.domain)
      server.master_or_slave    = server.master ? "master" : "slave"
      server.master_domain      = cluster.servers.collect { |s| s.domain if s.master }.first
      server.master_port        = cluster.servers.collect { |s| s.port if s.master }.first
      server.container_name     = "#{server.domain}-postgres-#{server.port}-#{server.master_or_slave}"
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
      fatal "The container names in this cluster are not unique" and exit unless names == names.uniq

      masters = cluster.servers.collect { |s| s.domain if s.master }
      fatal "You can't set more than one master" and exit unless masters.compact.length == 1
    end
  end

  task :ensure_setup => [:load_settings, :ensure_cluster_data_uniqueness] do
  end

  desc "Setup one or more PostgreSQL instances"
  task :setup => :ensure_setup do
    cluster = @cluster
    cluster.servers.each do |server|
      Rake::Task[:ensure_access_docker].invoke(server.domain)
      on "#{cluster.ssh_user}@#{server.domain}" do
        if container_exists?(server) and container_is_running?(server)
          restart = false
        else
          restart = true
        end
        cluster.image.config_files.each do |config_file|
          Rake::Task[:upload_config_file].invoke(server.domain, config_file)
          within '/tmp' do
            as 'root' do
              unless test "diff", config_file, "#{server.conf_path}/#{config_file}"
                execute("mkdir", "-p", server.conf_path)
                execute("mkdir", "-p", server.data_path)
                execute("mv", "-b", config_file, "#{server.conf_path}/#{config_file}")
                execute("chown", "-R", "102:105", server.conf_path)
                execute("chown", "-R", "102:105", server.data_path)
                execute("chmod", "700", server.conf_path)
                execute("chmod", "700", server.data_path)
                restart = true
              end
            end
          end
        end
        Rake::Task[:restart].invoke(server.master_or_slave) if restart
        if server.master
          if role_exists?(server, "replicator")
            info "Role #{role} already exists on #{server.domain}"
          else
            Rake::Task[:create_role].invoke(server.domain, "replicator")
          end
        end
      end
    end
  end

  desc "Check the status of one or more PostgreSQL instances"
  task :status, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    domain_found = false
    cluster.servers.each do |server|
      next unless args.domain == server.domain
      domain_found = true
      on "#{cluster.ssh_user}@#{server.domain}" do
        if container_exists?(server)
          info "#{server.container_name} exists on #{server.domain}"
          if container_is_running?(server)
            info ""
            info "#{server.container_name} is running on #{server.domain}"
            info ""
            Rake::Task[:list_roles].invoke(server.domain)
            info ""
            Rake::Task[:list_databases].invoke(server.domain)
            info ""
            Rake::Task[:streaming_status].invoke(server.domain)
          else
            info "#{server.container_name} is not running on #{server.domain}"
          end
        else
          info "#{server.container_name} does not exist on #{server.domain}"
        end
      end
    end
    fatal "Server domain #{args.domain} not found in the configuration" unless domain_found
  end

  desc "Initiate replication from master to slave(s)"
  task :replicate => :ensure_setup do
    cluster = @cluster
    cluster.servers.each do |server|
      next if server.master
      on "#{cluster.ssh_user}@#{server.domain}" do
        execute("docker", "stop", server.container_name) if container_is_running?(server)
        as 'root' do
          fatal "#{server.data_path} on #{server.domain} is not empty, cannot continue!" and exit if test("ls", "-A", "#{server.data_path}/*")
          capture(
            "bash", "-il", "-c", "\"docker", "run", "--rm", "--interactive", "--user", "postgres",
            "--volume", "#{server.data_path}:#{cluster.image.data_path}:rw",
            "--entrypoint", "/usr/bin/pg_basebackup",
            cluster.image.name,
            "-w", "-h", server.master_domain, "-p", server.master_port,
            "-U", "replicator", "-D", cluster.image.data_path, "-v\""
          ).each_line { |line| info line }
          @cluster = cluster
          @server = server
          template_path = File.expand_path("templates/recovery.conf.erb")
          host_config   = ERB.new(File.new(template_path).read).result(binding)
          upload! StringIO.new(host_config), "/tmp/recovery.conf"
          execute("mv", "/tmp/recovery.conf", "#{server.data_path}/recovery.conf")
          execute("chown", "102:105", "#{server.data_path}/recovery.conf")
          execute("chmod", "700", "#{server.data_path}/recovery.conf")
          execute("docker", "start", server.container_name)
        end
      end
    end
  end

  desc "Restore dump_file in /tmp on the master server into database_name"
  task :restore, [:dump_file, :database_name]  => :ensure_setup do |t, args|
    cluster = @cluster
    Rake::Task[:fatal_database_not_found].invoke(args.database_name)
    cluster.databases.each do |database|
      next unless args.database_name == database.name
      cluster.servers.each do |server|
        on "#{cluster.ssh_user}@#{server.domain}" do
          unless cluster.databases.collect { |d| d.name }.include? args.database_name
            fatal "#{args.database_name} is not defined in the settings" and exit
          end
          if server.master
            ensure_role(cluster, server, database.role)
            if database_exists?(cluster, server, database)
              info "Database #{database.name} already exists on #{server.domain}"
            else
              create_database(cluster, server, database)
              grant_database(cluster, server, database)
              #create_database(cluster, server, database).each_line { |line| info line }
              #grant_database(cluster, server, database).each_line { |line| info line }
            end
            execute("docker", "run", "--rm", "--interactive",
              "--volume", "/tmp:/tmp:rw",
              "--entrypoint", "/bin/bash",
              "--link", "#{server.container_name}:postgres", cluster.image.name,
              "-c", "'/usr/bin/pg_restore", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
              "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres",
              "-d", database.name, "-F", "tar", "-v", "/tmp/#{args.dump_file}'"
            )
          end
        end
      end
    end
  end

  desc "Restart postgres on the master server or the slave servers"
  task :restart, [:master_or_slave] => :ensure_setup do |t, args|
    cluster = @cluster
    cluster.servers.each do |server|
      next unless args.master_or_slave == server.master_or_slave
      on "#{cluster.ssh_user}@#{server.domain}" do
        if container_exists?(server)
          if container_is_running?(server)
            warn "Restarting a running container named #{server.container_name}"
            execute("docker", "restart", server.container_name)
          else
            warn "Starting an existing but non-running container named #{server.container_name}"
            execute("docker", "start", server.container_name)
          end
        else
          warn "Starting a new container named #{server.container_name}"
          as 'root' do
            execute("docker", "run", cluster.docker_init_command)
            execute("docker", "run", server.docker_run_command)
          end
        end
        sleep 2
        fatal("Container #{server.container_name} on #{server.domain} did not stay running more than 2 seconds!") and exit unless container_is_running?(server)
      end
    end
  end

  task :fatal_domain_not_found, [:domain] do |t, args|
    run_locally do
      cluster = @cluster
      domain_found = false
      cluster.servers.each do |server|
        next unless server.domain == args.domain
        domain_found = true
      end
      fatal "Server domain #{args.domain} not found in the configuration" unless domain_found
    end
  end

  task :fatal_role_not_found, [:role_name] do |t, args|
    run_locally do
      cluster = @cluster
      role_found = false
      cluster.databases.each do |database|
        next unless database.role == args.role_name
        role_found = true
      end
      fatal "Role #{args.role_name} not found in the configuration" unless role_found
    end
  end

  task :fatal_database_not_found, [:database_name] do |t, args|
    run_locally do
      cluster = @cluster
      database_found = false
      cluster.databases.each do |database|
        next unless database.name == args.database_name
        database_found = true
      end
      fatal "Database #{args.domain} not found in the configuration" unless database_found
    end
  end

  task :fatal_config_file_not_found, [:config_file] do |t, args|
    run_locally do
      cluster = @cluster
      config_file_found = false
      cluster.config_files.each do |config_file|
        next unless config_file == args.config_file
        config_file_found = true
      end
      fatal "Config file #{args.config_file} not found in the configuration" unless config_file_found
      config_template_found = test("ls", "-A", "templates/#{args.config_file}.erb")
      fatal "Config template file templates/#{args.config_file}.erb not found locally" unless config_template_found
    end
  end

  task :ensure_access_docker, [:domain] do |t, args|
    cluster = @cluster
    on "#{cluster.ssh_user}@#{args.domain}" do
      as cluster.ssh_user do
        unless test("docker", "ps")
          execute("sudo", "usermod", "-a", "-G", "docker", cluster.ssh_user)
          fatal "Newly added to docker group, this run will fail, next run will succeed. Simply try again."
        end
      end
    end
  end

  task :upload_config_file, [:domain, :config_file] => :ensure_setup do |t, args|
    cluster = @cluster
    Rake::Task[:fatal_domain_not_found].invoke(args.domain)
    Rake::Task[:fatal_config_file_not_found].invoke(args.config_file)
    cluster.servers.each do |server|
      next unless server.domain == args.domain
      on "#{cluster.ssh_user}@#{args.domain}" do
        @cluster  = cluster # needed for ERB
        @server   = server  # needed for ERB
        template_path = File.expand_path("templates/#{args.config_file}.erb")
        host_config   = ERB.new(File.new(template_path).read).result(binding)
        upload! StringIO.new(host_config), "/tmp/#{args.config_file}"
      end
    end
  end

  task :list_roles, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    Rake::Task[:fatal_domain_not_found].invoke(args.domain)
    cluster.servers.each do |server|
      next unless server.domain == args.domain
      on "#{cluster.ssh_user}@#{args.domain}" do
        capture("docker", "run", "--rm",
          "--entrypoint", "/bin/bash",
          "--link", "#{args.container_name}:postgres", cluster.image.name,
          "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
          "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres",
          "-c", "\"\\du\"'").each_line { |line| info line }
      end
    end
  end

  task :list_databases, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    Rake::Task[:fatal_domain_not_found].invoke(args.domain)
    cluster.servers.each do |server|
      next unless server.domain == args.domain
      on "#{cluster.ssh_user}@#{args.domain}" do
        capture "docker", "run", "--rm",
          "--entrypoint", "/bin/bash",
          "--link", "#{server.container_name}:postgres", cluster.image.name,
          "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
          "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres",
          "-c", "\"\\l\"'".each_line { |line| info line }
      end
    end
  end

  task :streaming_status, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    Rake::Task[:fatal_domain_not_found].invoke(args.domain)
    cluster.servers.each do |server|
      next unless server.domain == args.domain
      on "#{cluster.ssh_user}@#{args.domain}" do
        if server.master
          info "Streaming status of #{server.container_name} on #{server.domain}:"
          capture("echo", "\"select", "*", "from", "pg_stat_replication;\"", "|",
            "docker", "run", "--rm", "--interactive",
            "--entrypoint", "/bin/bash",
            "--link", "#{server.container_name}:postgres", cluster.image.name,
            "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
            "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'").each_line { |line| info line }
        else
          info "Streaming status of #{server.container_name} on #{server.domain}:"
          capture("echo", "\"select", "now()", "-", "pg_last_xact_replay_timestamp()",
            "AS", "replication_delay;\"", "|",
            "docker", "run", "--rm", "--interactive",
            "--entrypoint", "/bin/bash",
            "--link", "#{server.container_name}:postgres", cluster.image.name,
            "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
            "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'").each_line { |line| info line }
        end
      end
    end
  end

  task :create_role, [:domain, :role_name] => :ensure_setup do |t, args|
    cluster = @cluster
    Rake::Task[:fatal_domain_not_found].invoke(args.domain)
    Rake::Task[:fatal_role_not_found].invoke(args.role_name)
    cluster.servers.each do |server|
      next unless server.domain == args.domain
      on "#{cluster.ssh_user}@#{args.domain}" do
        execute("echo", "\"CREATE", "ROLE", "\\\"#{args.role_name}\\\"",
          "WITH", "LOGIN", "ENCRYPTED", "PASSWORD", "'#{args.role_name}'", "REPLICATION", "CREATEDB;\"", "|",
          "docker", "run", "--rm", "--interactive",
          "--entrypoint", "/bin/bash",
          "--link", "#{server.container_name}:postgres", cluster.image.name,
          "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
          "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'")
      end
    end
  end

  task :create_database, [:domain, :database_name] => :ensure_setup do |t, args|
    cluster = @cluster
    Rake::Task[:fatal_domain_not_found].invoke(args.domain)
    Rake::Task[:fatal_database_not_found].invoke(args.database_name)
    cluster.databases.each do |database|
      next unless database.name == args.database_name
      cluster.servers.each do |server|
        next unless server.domain == args.domain
        on "#{cluster.ssh_user}@#{args.domain}" do
          execute("echo", "\"CREATE", "DATABASE", "\\\"#{database.name}\\\"",
            "WITH", "OWNER", "\\\"#{database.role}\\\"", "TEMPLATE",
            "template0", "ENCODING", "'UTF8';\"", "|",
            "docker", "run", "--rm", "--interactive",
            "--entrypoint", "/bin/bash",
            "--link", "#{server.container_name}:postgres", cluster.image.name,
            "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
            "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'")
        end
      end
    end
  end

  task :grant_database, [:domain, :database_name] => :ensure_setup do |t, args|
    cluster = @cluster
    Rake::Task[:fatal_domain_not_found].invoke(args.domain)
    Rake::Task[:fatal_database_not_found].invoke(args.database_name)
    cluster.databases.each do |database|
      next unless database.name == args.database_name
      cluster.servers.each do |server|
        on "#{cluster.ssh_user}@#{args.domain}" do
          execute("echo", "\"GRANT", "ALL", "PRIVILEGES", "ON", "DATABASE",
            "\\\"#{database.name}\\\"", "to", "\\\"#{database.role}\\\";\"", "|",
            "docker", "run", "--rm", "--interactive",
            "--entrypoint", "/bin/bash",
            "--link", "#{server.container_name}:postgres", cluster.image.name,
            "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
            "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'")
        end
      end
    end
  end

  private
    def role_exists?(server, role)
      test("echo", "\"SELECT", "*", "FROM", "pg_user", "WHERE", "usename", "=", "'#{role}';\"", "|",
        "docker", "run", "--rm", "--interactive",
        "--entrypoint", "/bin/bash",
        "--link", "#{server.container_name}:postgres", cluster.image.name,
        "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'", "|",
        "grep", "-q", "'#{role}'")
    end

    def database_exists?(cluster, server, database)
      test "docker", "run", "--rm",
        "--entrypoint", "/bin/bash",
        "--link", "#{server.container_name}:postgres", cluster.image.name,
        "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres", "-lqt", "|",
        "cut", "-d\\|", "-f1", "|", "grep", "-w", "#{database.name}'"
    end

    def container_exists?(server)
      test "docker", "inspect", server.container_name
    end

    def container_is_running?(server)
      (capture "docker", "inspect",
        "--format='{{.State.Running}}'",
        server.container_name).strip == "true"
    end
end
