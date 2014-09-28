require 'erb'

require './postgresinator.rb'

## NOTES:
# tasks without 'desc' description lines are for manual debugging of this
#   deployment code.
#
# postgrestinator does not currently support more than one master or
#   slave per domain for a particular cluster configuration file, but
#   that can be accomplished with multiple postgresinator.rb configs.
#
# we've choosen to only pass strings (if anything) to tasks. this allows tasks to be
#   debugged indivudually. only private methods take ruby objects.

namespace :pg do

  task :ensure_setup => ['config:load_settings', 'config:ensure_cluster_data_uniqueness'] do |t, args|
    Rake::Task['config:config_file_not_found'].invoke(args.config_file) unless args.config_file.nil?
    Rake::Task['config:database_not_found'].invoke(args.database_name) unless args.database_name.nil?
    Rake::Task['config:domain_not_found'].invoke(args.domain) unless args.domain.nil?
    Rake::Task['config:role_not_found'].invoke(args.role_name) unless args.role_name.nil?
  end

  desc "Setup one or more PostgreSQL instances"
  task :setup => :ensure_setup do
    # instance variables are lost inside SSHKit's 'on' block, so
    #   at the beginning of each task we assign @cluster to cluster.
    cluster = @cluster
    cluster.servers.each do |server|
      Rake::Task['pg:ensure_access_docker'].invoke(server.domain)
      Rake::Task['pg:ensure_access_docker'].reenable
      on "#{cluster.ssh_user}@#{server.domain}" do
        config_file_changed = false
        cluster.image.config_files.each do |config_file|
          next if(config_file == "recovery.conf" and server.master)
          if config_file_differs?(cluster, server, config_file)
            Rake::Task['pg:install_config_file'].invoke(server.domain, config_file)
            Rake::Task['pg:install_config_file'].reenable
            config_file_changed = true
          end
        end
        fatal_message = "Container #{server.container_name} on #{server.domain} did not stay running more than 2 seconds!"
        unless container_exists?(server)
          # no need to run create_container's prerequisite task :ensure_config_files here, so we clear_prerequisites.
          Rake::Task['pg:create_container'].clear_prerequisites
          Rake::Task['pg:create_container'].invoke(server.domain)
          Rake::Task['pg:create_container'].reenable
          sleep 2
          fatal fatal_message and raise unless container_is_running?(server)
        else
          unless container_is_running?(server)
            Rake::Task['pg:start_container'].invoke(server.domain)
            Rake::Task['pg:start_container'].reenable
            sleep 2
            fatal fatal_message and raise unless container_is_running?(server)
          else
            if config_file_changed
              Rake::Task['pg:restart_container'].invoke(server.domain)
              Rake::Task['pg:restart_container'].reenable
              sleep 2
              fatal fatal_message and raise unless container_is_running?(server)
            else
              info "No config file changes for #{server.container_name} and it is already running; we're setup!"
            end
          end
        end
        if server.master
          if role_exists?(cluster, server, "replicator")
            info "Role 'replicator' already exists on #{server.domain}"
          else
            Rake::Task['pg:create_role'].invoke(server.domain, "replicator", true)
            Rake::Task['pg:create_role'].reenable
          end
        end
      end
    end
  end

  desc "Check the statuses of each PostgreSQL instance in the cluster"
  task :statuses => :ensure_setup do
    cluster = @cluster
    cluster.servers.each do |server|
      Rake::Task['pg:status'].invoke(server.domain)
      Rake::Task['pg:status'].reenable
    end
  end

  desc "Check the status of the PostgreSQL instance on domain"
  task :status, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    cluster.servers.each do |server|
      next unless args.domain == server.domain
      on "#{cluster.ssh_user}@#{server.domain}" do
        if container_exists?(server)
          info "#{server.container_name} exists on #{server.domain}"
          if container_is_running?(server)
            info ""
            info "#{server.container_name} is running on #{server.domain}"
            info ""
            Rake::Task['pg:list_roles'].invoke(server.domain)
            info ""
            Rake::Task['pg:list_databases'].invoke(server.domain)
            info ""
            Rake::Task['pg:streaming_status'].invoke(server.domain)
          else
            info "#{server.container_name} is not running on #{server.domain}"
          end
        else
          info "#{server.container_name} does not exist on #{server.domain}"
        end
      end
    end
  end

  # TODO: figure out when and how to invoke/setup replication
  #desc "Initiate replication from master to slave(s)"
  task :replicate => :ensure_setup do
    cluster = @cluster
    cluster.servers.each do |server|
      next if server.master
      on "#{cluster.ssh_user}@#{server.domain}" do
        as 'root' do
          fatal_message = "#{server.data_path} on #{server.domain} is not empty, cannot continue! " +
            "You'll need to delete those files by hand. Be sure you are deleting unimportant data!"
          fatal fatal_message and raise if files_in_data_path?(server)
          execute("docker", "stop", server.container_name) if container_is_running?(server)
          capture(
            "bash", "-il", "-c", "\"docker", "run", "--rm", "--interactive", "--user", "postgres",
            "--volume", "#{server.data_path}:#{cluster.image.data_path}:rw",
            "--entrypoint", "/usr/bin/pg_basebackup",
            cluster.image.name,
            "-w", "-h", server.master_domain, "-p", server.master_port,
            "-U", "replicator", "-D", cluster.image.data_path, "-v\""
          ).each_line { |line| info line }
          Rake::Task['pg:install_config_file'].invoke(server.domain, "recovery.conf")
          Rake::Task['pg:install_config_file'].reenable
          execute("docker", "start", server.container_name)
        end
      end
    end
  end

  desc "Restore dump_file in /tmp on the master server into database_name"
  task :restore, [:dump_file, :database_name]  => :ensure_setup do |t, args|
    cluster = @cluster
    cluster.databases.each do |database|
      next unless args.database_name == database.name
      cluster.servers.each do |server|
        on "#{cluster.ssh_user}@#{server.domain}" do
          unless cluster.databases.collect { |d| d.name }.include? args.database_name
            fatal "#{args.database_name} is not defined in the settings" and raise
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

  task :ensure_config_files, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    cluster.servers.each do |server|
      next unless args.domain == server.domain
      on "#{cluster.ssh_user}@#{server.domain}" do
        cluster.image.config_files.each do |config_file|
          if config_file_differs?(cluster, server, config_file)
            Rake::Task['pg:install_config_file'].invoke(server.domain, config_file)
            Rake::Task['pg:install_config_file'].reenable
          end
        end
      end
    end
  end

  task :create_container, [:domain] => :ensure_config_files do |t, args|
    cluster = @cluster
    cluster.servers.each do |server|
      next unless args.domain == server.domain
      on "#{cluster.ssh_user}@#{server.domain}" do
        warn "Starting a new container named #{server.container_name}"
        as 'root' do
          execute("docker", "run", cluster.docker_init_command) if server.master
          execute("docker", "run", server.docker_run_command)
        end
      end
    end
  end

  task :restart_container, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    cluster.servers.each do |server|
      next unless args.domain == server.domain
      on "#{cluster.ssh_user}@#{server.domain}" do
        warn "Restarting a running container named #{server.container_name}"
        execute("docker", "restart", server.container_name)
      end
    end
  end

  task :start_container, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    cluster.servers.each do |server|
      next unless args.domain == server.domain
      on "#{cluster.ssh_user}@#{server.domain}" do
        warn "Starting an existing but non-running container named #{server.container_name}"
        execute("docker", "start", server.container_name)
      end
    end
  end

  desc "Print the command to enter psql interactive mode on domain"
  task :print_interactive, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    cluster.servers.each do |server|
      next unless args.domain == server.domain
      run_locally do
        info "You can paste the following command into a terminal on #{server.domain} to enter psql interactive mode for #{server.container_name}:"
        info "docker run --rm --interactive --tty --link #{server.container_name}:postgres --entrypoint /bin/bash #{cluster.image.name} -lic '/usr/bin/psql -h $POSTGRES_PORT_5432_TCP_ADDR -p $POSTGRES_PORT_5432_TCP_PORT -U postgres'"
      end
    end
  end

  task :ensure_access_docker, [:domain] => :ensure_setup do |t, args|
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

  task :install_config_file, [:domain, :config_file] => :ensure_setup do |t, args|
    cluster = @cluster
    cluster.servers.each do |server|
      next unless server.domain == args.domain
      on "#{cluster.ssh_user}@#{args.domain}" do
        as 'root' do
          execute("mkdir", "-p", server.conf_path) unless test("test", "-d", server.conf_path)
          execute("mkdir", "-p", server.data_path) unless test("test", "-d", server.data_path)
          generated_config_file = generate_config_file(cluster, server, args.config_file)
          upload! StringIO.new(generated_config_file), "/tmp/#{args.config_file}"
          execute("mv", "/tmp/#{args.config_file}", "#{server.data_path}/#{args.config_file}")
          execute("chown", "-R", "102:105", server.conf_path)
          execute("chown", "-R", "102:105", server.data_path)
          execute("chmod", "700", server.conf_path)
          execute("chmod", "700", server.data_path)
        end
      end
    end
  end

  task :list_roles, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    cluster.servers.each do |server|
      next unless server.domain == args.domain
      on "#{cluster.ssh_user}@#{args.domain}" do
        capture("docker", "run", "--rm",
          "--entrypoint", "/bin/bash",
          "--link", "#{server.container_name}:postgres", cluster.image.name,
          "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
          "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres",
          "-c", "\"\\du\"'").each_line { |line| info line }
      end
    end
  end

  task :list_databases, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    cluster.servers.each do |server|
      next unless server.domain == args.domain
      on "#{cluster.ssh_user}@#{args.domain}" do
        capture("docker", "run", "--rm",
          "--entrypoint", "/bin/bash",
          "--link", "#{server.container_name}:postgres", cluster.image.name,
          "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
          "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres",
          "-c", "\"\\l\"'").each_line { |line| info line }
      end
    end
  end

  task :streaming_status, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
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
    Rake::Task[].invoke(args.domain)
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
    def files_in_data_path?(server)
      test("[", "\"$(ls", "-A", "#{server.data_path})\"", "]")
    end

    def config_file_differs?(cluster, server, config_file)
      generated_config_file = generate_config_file(cluster, server, config_file)
      capture("cat", "#{server.conf_path}/#{config_file}") == generated_config_file
    end

    def generate_config_file(cluster, server, config_file)
      @cluster      = cluster # needed for ERB
      @server       = server  # needed for ERB
      template_path = File.expand_path("templates/#{args.config_file}.erb")
      ERB.new(File.new(template_path).read).result(binding)
    end

    def role_exists?(cluster, server, role)
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
