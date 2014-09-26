require './postgresinator.rb'

namespace :pg do

  @cluster = Hashie::Mash.new(PostgresCluster.settings)

  desc "Setup one or more PostgreSQL instances"
  task :setup => :load_settings do
    Rake::Task["pg:ensure_access_docker"].invoke
    Rake::Task["pg:upload_config_files"].invoke
    cluster = @cluster
    cluster.servers.each do |server|
      on "#{ENV["USER"]}@#{server.domain}" do
        if exists?(server) and is_running?(server)
          restart = false
        else
          restart = true
        end
        cluster.image.config_files.each do |config_file|
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
        restart_postgres(cluster, server) if restart
        ensure_role(cluster, server, "replicator") if server.master
      end
    end
  end

  desc "Check the status of one or more PostgreSQL instances"
  task :status => :load_settings do
    cluster = @cluster
    @cluster.servers.each do |server|
      on "#{ENV["USER"]}@#{server.domain}" do
        if exists?(server)
          info "#{server.container_name} exists on #{server.domain}"
          if is_running?(server)
            info ""
            info "#{server.container_name} is running on #{server.domain}"
            info ""
            list_roles(cluster, server).each_line { |line| info line }
            info ""
            list_databases(cluster, server).each_line { |line| info line }
            info ""
            info "Streaming status of #{server.container_name} on #{server.domain}:"
            streaming_status(cluster, server).each_line { |line| info line }
          else
            info "#{server.container_name} is not running on #{server.domain}"
          end
        else
          info "#{server.container_name} does not exist on #{server.domain}"
        end
      end
    end
  end

  desc "Initiate replication from master to slave(s)"
  task :replicate => :load_settings do
    cluster = @cluster
    cluster.servers.each do |server|
      unless server.master
        on "#{ENV["USER"]}@#{server.domain}" do
          execute("docker", "stop", server.container_name) if is_running?(server)
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
  end

  desc "Restore a database file into the master server, from a tar file in /tmp on that server."
  task :restore, [:dump_file, :database_name]  => :load_settings do |t, args|
    cluster = @cluster
    cluster.databases.each do |database|
      next unless args.database_name == database.name
      cluster.servers.each do |server|
        on "#{ENV["USER"]}@#{server.domain}" do
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

  private

    task :load_settings do
      @cluster.servers.each do |server|
        server.ip = Resolv.getaddress(server.domain)
        server.master ? server.master_or_slave = "master" : server.master_or_slave = "slave"
        server.master_domain  = @cluster.servers.collect { |s| s.domain if s.master }.first
        server.master_port    = @cluster.servers.collect { |s| s.port if s.master }.first
        server.container_name = "#{server.domain}-postgres-#{server.port}-#{server.master_or_slave}"
        server.data_path = "/#{server.container_name}-data"
        server.conf_path = "/#{server.container_name}-conf"
        server.docker_run_command = [
          "--detach", "--tty", "--user", "postgres",
          "--name", server.container_name,
          "--volume", "#{server.data_path}:#{@cluster.image.data_path}:rw",
          "--volume", "#{server.conf_path}:#{@cluster.image.conf_path}:rw",
          "--expose", "5432",
          "--publish", "0.0.0.0:#{server.port}:5432",
          @cluster.image.name
        ]
        if server.master
          @cluster.docker_init_command = [
            #"--interactive", "--rm", "--user", "root",
            "--rm", "--user", "root",
            "--volume", "#{server.data_path}:/postgresql-data:rw",
            "--entrypoint", "/usr/bin/rsync",
            @cluster.image.name, "-ahP", "#{@cluster.image.data_path}/", "/postgresql-data/"
          ]
        end
      end
      Rake::Task["pg:ensure_cluster_data_uniquenesses"].invoke
    end

    task :ensure_cluster_data_uniquenesses do
      cluster = @cluster
      run_locally do
        names = cluster.servers.collect { |s| s.container_name }
        fatal "The container names in this cluster are not unique" and exit unless names == names.uniq

        masters = cluster.servers.collect { |s| s.domain if s.master }
        fatal "You can't set more than one master" and exit unless masters.compact.length == 1
      end
    end

    task :upload_config_files do
      cluster = @cluster
      cluster.servers.each do |server|
        on "#{ENV["USER"]}@#{server.domain}" do
          cluster.image.config_files.each do |config_file|
            @cluster = cluster
            @server = server
            template_path = File.expand_path("templates/#{config_file}.erb")
            host_config   = ERB.new(File.new(template_path).read).result(binding)
            upload! StringIO.new(host_config), "/tmp/#{config_file}"
          end
        end
      end
    end

    task :ensure_access_docker do
      @cluster.servers.each do |server|
        on "#{ENV["USER"]}@#{server.domain}" do
          unless test("docker", "ps")
            execute("sudo", "usermod", "-a", "-G", "docker", "#{ENV["USER"]}")
            fatal "Newly added to docker group, this run will fail, next run will succeed. Simply try again."
          end
        end
      end
    end

    def list_roles(cluster, server)
      capture "docker", "run", "--rm",
        "--entrypoint", "/bin/bash",
        "--link", "#{server.container_name}:postgres", cluster.image.name,
        "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres",
        "-c", "\"\\du\"'"
    end

    def list_databases(cluster, server)
      capture "docker", "run", "--rm",
        "--entrypoint", "/bin/bash",
        "--link", "#{server.container_name}:postgres", cluster.image.name,
        "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres",
        "-c", "\"\\l\"'"
    end

    def streaming_status(cluster, server)
      if server.master
        capture "echo", "\"select", "*", "from", "pg_stat_replication;\"", "|",
          "docker", "run", "--rm", "--interactive",
          "--entrypoint", "/bin/bash",
          "--link", "#{server.container_name}:postgres", cluster.image.name,
          "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
          "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'"
      else
        capture "echo", "\"select", "now()", "-", "pg_last_xact_replay_timestamp()",
          "AS", "replication_delay;\"", "|",
          "docker", "run", "--rm", "--interactive",
          "--entrypoint", "/bin/bash",
          "--link", "#{server.container_name}:postgres", cluster.image.name,
          "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
          "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'"
      end
    end

    def restart_postgres(cluster, server)
      if exists?(server)
        if is_running?(server)
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
      fatal("Container #{server.container_name} on #{server.domain} did not stay running more than 2 seconds!") and exit unless is_running?(server)
    end

    def exists?(server)
      test "docker", "inspect", server.container_name
    end

    def is_running?(server)
      (capture "docker", "inspect",
        "--format='{{.State.Running}}'",
        server.container_name).strip == "true"
    end

    def ensure_role(cluster, server, role)
      unless test("echo", "\"SELECT", "*", "FROM", "pg_user", "WHERE", "usename", "=", "'#{role}';\"", "|",
        "docker", "run", "--rm", "--interactive",
        "--entrypoint", "/bin/bash",
        "--link", "#{server.container_name}:postgres", cluster.image.name,
        "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'", "|",
        "grep", "-q", "'#{role}'")
        execute("echo", "\"CREATE", "ROLE", "\\\"#{role}\\\"",
          "WITH", "LOGIN", "ENCRYPTED", "PASSWORD", "'#{role}'", "REPLICATION", "CREATEDB;\"", "|",
          "docker", "run", "--rm", "--interactive",
          "--entrypoint", "/bin/bash",
          "--link", "#{server.container_name}:postgres", cluster.image.name,
          "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
          "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'")
      else
        info "Role #{role} already exists on #{server.domain}"
      end
    end

    def database_exists?(cluster, server, database)
      test "docker", "run", "--rm",
        "--entrypoint", "/bin/bash",
        "--link", "#{server.container_name}:postgres", cluster.image.name,
        "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres", "-lqt", "|",
        "cut", "-d\\|", "-f1", "|", "grep", "-w", "#{database.name}'"
    end

    def create_database(cluster, server, database)
      execute("echo", "\"CREATE", "DATABASE", "\\\"#{database.name}\\\"",
        "WITH", "OWNER", "\\\"#{database.role}\\\"", "TEMPLATE",
        "template0", "ENCODING", "'UTF8';\"", "|",
        "docker", "run", "--rm", "--interactive",
        "--entrypoint", "/bin/bash",
        "--link", "#{server.container_name}:postgres", cluster.image.name,
        "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'")
    end

    def grant_database(cluster, server, database)
      execute("echo", "\"GRANT", "ALL", "PRIVILEGES", "ON", "DATABASE",
        "\\\"#{database.name}\\\"", "to", "\\\"#{database.role}\\\";\"", "|",
        "docker", "run", "--rm", "--interactive",
        "--entrypoint", "/bin/bash",
        "--link", "#{server.container_name}:postgres", cluster.image.name,
        "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'")
    end
end
