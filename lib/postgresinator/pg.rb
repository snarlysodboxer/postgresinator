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
#   debugged individually. only private methods take ruby objects.

namespace :pg do

  task :ensure_setup => ['config:load_settings', 'config:ensure_cluster_data_uniqueness'] do |t, args|
    # use 'rake pg:COMMAND debug=true' for debugging
    SSHKit.config.output_verbosity = Logger::DEBUG if ENV['debug'] == "true"
    Rake::Task['config:config_file_not_found'].invoke(args.config_file) unless args.config_file.nil?
    Rake::Task['config:database_not_found'].invoke(args.database_name) unless args.database_name.nil?
    Rake::Task['config:domain_not_found'].invoke(args.domain) unless args.domain.nil?
    Rake::Task['config:role_not_found'].invoke(args.role_name) unless(args.role_name.nil? or args.force == "true")
  end

  desc "Idempotently setup one or more PostgreSQL instances using values in ./postgresinator.rb"
  task :setup => :ensure_setup do
    # instance variables are lost inside SSHKit's 'on' block, so
    #   at the beginning of each task we assign @cluster to cluster.
    cluster = @cluster
    cluster.servers.each do |server|
      Rake::Task['pg:ensure_access_docker'].invoke(server.domain)
      Rake::Task['pg:ensure_access_docker'].reenable
      # 'on', 'run_locally', 'as', 'execute', 'info', 'warn', and 'fatal' are from SSHKit
      on "#{cluster.ssh_user}@#{server.domain}" do
        config_file_changed = false
        cluster.image.config_files.each do |config_file|
          next if config_file == "recovery.conf"
          if config_file_differs?(cluster, server, config_file)
            Rake::Task['pg:install_config_file'].invoke(server.domain, config_file)
            Rake::Task['pg:install_config_file'].reenable
            config_file_changed = true
          end
        end
        unless container_exists?(server)
          # create_container's prerequisite task :ensure_config_files is for manual
          #   use of create_container, so here we clear_prerequisites.
          Rake::Task['pg:create_container'].clear_prerequisites
          Rake::Task['pg:create_container'].invoke(server.domain)
          Rake::Task['pg:create_container'].reenable
        else
          unless container_is_running?(server)
            Rake::Task['pg:start_container'].invoke(server.domain)
            Rake::Task['pg:start_container'].reenable
          else
            if config_file_changed
              Rake::Task['pg:restart_container'].invoke(server.domain)
              Rake::Task['pg:restart_container'].reenable
            else
              info "No config file changes for #{server.container_name} and it is already running; we're setup!"
            end
          end
        end
        #sleep to allow postgres to start up before subsequent commands against it
        sleep 3
        if server.master
          if role_exists?(cluster, server, "replicator")
            info "Role 'replicator' already exists on #{server.domain}"
          else
            Rake::Task['pg:create_role'].invoke(server.domain, "replicator")
            Rake::Task['pg:create_role'].reenable
          end
        end
      end
    end
  end

  desc "Check the statuses of each PostgreSQL instance in the cluster."
  task :statuses => :ensure_setup do
    cluster = @cluster
    cluster.servers.each do |server|
      Rake::Task['pg:status'].invoke(server.domain)
      Rake::Task['pg:status'].reenable
    end
  end

  desc "Check the status of the PostgreSQL instance on 'domain'."
  task :status, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{server.domain}" do
      if container_exists?(server)
        info "#{server.container_name} exists on #{server.domain}"
        if container_is_running?(server)
          info ""
          info "#{server.container_name} is running on #{server.domain}"
          info ""
          Rake::Task['pg:list_roles'].invoke(server.domain)
          Rake::Task['pg:list_roles'].reenable
          info ""
          Rake::Task['pg:list_databases'].invoke(server.domain)
          Rake::Task['pg:list_databases'].reenable
          info ""
          Rake::Task['pg:streaming_status'].invoke(server.domain)
          Rake::Task['pg:streaming_status'].reenable
        else
          info "#{server.container_name} is not running on #{server.domain}"
        end
      else
        info "#{server.container_name} does not exist on #{server.domain}"
      end
    end
  end

  desc "Restore 'dump_file' in /tmp on the master server into 'database_name'."
  task :restore, [:dump_file, :database_name]  => :ensure_setup do |t, args|
    cluster = @cluster
    database = cluster.databases.select { |d| d.name == args.database_name }.first
    # we only restore on the master server
    server = cluster.servers.select { |s| s.master }.first
    on "#{cluster.ssh_user}@#{server.domain}" do
      unless cluster.databases.collect { |d| d.name }.include? args.database_name
        fatal "#{args.database_name} is not defined in the settings" and raise
      end
      if server.master
        if role_exists?(cluster, server, database.role)
          info "Role #{database.role} already exists on #{server.domain}"
        else
          Rake::Task['pg:create_role'].invoke(server.domain, database.role)
        end
        clean = ""
        if database_exists?(cluster, server, database)
          confirm_database_overwrite? ? clean = "--clean" : exit(0)
        else
          Rake::Task['pg:create_database'].invoke(server.domain, database.name)
          Rake::Task['pg:grant_database'].invoke(server.domain, database.name)
        end
        execute("docker", "run", "--rm",
          "--volume", "/tmp:/tmp:rw",
          "--entrypoint", "/bin/bash",
          "--link", "#{server.container_name}:postgres", cluster.image.name,
          "-c", "'/usr/bin/pg_restore", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
          "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres", clean,
          "-d", database.name, "-F", "tar", "-v", "/tmp/#{args.dump_file}'"
        )
      end
    end
  end

  desc "Print the command to enter psql interactive mode on 'domain'."
  task :print_interactive, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    run_locally do
      info "You can paste the following command into a terminal on #{server.domain} to enter psql interactive mode for #{server.container_name}:"
      info "docker run --rm --interactive --tty --link #{server.container_name}:postgres --entrypoint /bin/bash #{cluster.image.name} -lic '/usr/bin/psql -h $POSTGRES_PORT_5432_TCP_ADDR -p $POSTGRES_PORT_5432_TCP_PORT -U postgres'"
    end
  end

  task :ensure_config_files, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{server.domain}" do
      cluster.image.config_files.each do |config_file|
        next if config_file == "recovery.conf"
        if config_file_differs?(cluster, server, config_file)
          Rake::Task['pg:install_config_file'].invoke(server.domain, config_file)
          Rake::Task['pg:install_config_file'].reenable
        end
      end
    end
  end

  task :create_container, [:domain] => :ensure_config_files do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    master_server = cluster.servers.select { |s| s.master }.first
    unless server.master
      on "#{cluster.ssh_user}@#{master_server.domain}" do
        fatal "Master must be running before creating a slave" and raise unless container_is_running?(master_server)
      end
    end
    on "#{cluster.ssh_user}@#{server.domain}" do
      warn "Starting a new container named #{server.container_name} on #{server.domain}"
      as 'root' do
        fatal_message = "#{server.data_path} on #{server.domain} is not empty, cannot continue! " +
          "You'll need to delete those files by hand. Be sure you are not deleting important data!"
        fatal fatal_message and raise if files_in_data_path?(server)
        execute("mkdir", "-p", server.data_path) unless test("test", "-d", server.data_path)
        execute("chown", "-R", "102:105", server.data_path)
        execute("chmod", "700", server.data_path)
        execute("docker", "run", server.docker_init_command)
        unless server.master
          execute("rm", "#{server.data_path}/*", "-rf")
          execute("docker", "run", server.docker_replicate_command)
          Rake::Task['pg:link_keys'].invoke(server.domain)
          Rake::Task['pg:link_keys'].reenable
          Rake::Task['pg:install_config_file'].invoke(server.domain, "recovery.conf")
          Rake::Task['pg:install_config_file'].reenable
        end
        execute("docker", "run", server.docker_run_command)
      end
    end
  end

  task :restart_container, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{server.domain}" do
      warn "Restarting a running container named #{server.container_name}"
      execute("docker", "restart", server.container_name)
      sleep 2
      fatal stay_running_message(server) and raise unless container_is_running?(server)
    end
  end

  task :start_container, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{server.domain}" do
      warn "Starting an existing but non-running container named #{server.container_name}"
      execute("docker", "start", server.container_name)
      sleep 2
      fatal stay_running_message(server) and raise unless container_is_running?(server)
    end
  end

  task :ensure_access_docker, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    on "#{cluster.ssh_user}@#{args.domain}" do
      as cluster.ssh_user do
        unless test("bash", "-c", "\"docker", "ps", "&>", "/dev/null\"")
          execute("sudo", "usermod", "-a", "-G", "docker", cluster.ssh_user)
          fatal "Newly added to docker group, this run will fail, next run will succeed. Simply try again."
        end
      end
    end
  end

  task :install_config_file, [:domain, :config_file] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      as 'root' do
        path = args.config_file == "recovery.conf" ? server.data_path : server.conf_path
        execute("mkdir", "-p", path) unless test("test", "-d", path)
        generated_config_file = generate_config_file(cluster, server, args.config_file)
        upload! StringIO.new(generated_config_file), "/tmp/#{args.config_file}"
        execute("mv", "/tmp/#{args.config_file}", "#{path}/#{args.config_file}")
        execute("chown", "-R", "102:105", path)
        execute("chmod", "700", path)
      end
    end
  end

  task :list_roles, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      capture("docker", "run", "--rm",
        "--entrypoint", "/bin/bash",
        "--link", "#{server.container_name}:postgres", cluster.image.name,
        "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres",
        "-c", "\"\\du\"'").each_line { |line| info line }
    end
  end

  task :list_databases, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      capture("docker", "run", "--rm",
        "--entrypoint", "/bin/bash",
        "--link", "#{server.container_name}:postgres", cluster.image.name,
        "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres",
        "-a", "-c", "\"\\l\"'").each_line { |line| info line }
    end
  end

  task :streaming_status, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      if server.master
        info "Streaming status of #{server.container_name} on #{server.domain}:"
        capture("echo", "\"select", "*", "from", "pg_stat_replication;\"", "|",
          "docker", "run", "--rm", "--interactive",
          "--entrypoint", "/bin/bash",
          "--link", "#{server.container_name}:postgres", cluster.image.name,
          "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
          "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres", "-xa'").each_line { |line| info line }
      else
        # TODO: fix this for slave servers
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

  task :create_role, [:domain, :role_name, :force] => :ensure_setup do |t, args|
    args.with_defaults :force => "false"
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      execute("echo", "\"CREATE", "ROLE", "\\\"#{args.role_name}\\\"",
        "WITH", "LOGIN", "ENCRYPTED", "PASSWORD", "'#{args.role_name}'",
        "REPLICATION", "CREATEDB;\"", "|",
        "docker", "run", "--rm", "--interactive",
        "--entrypoint", "/bin/bash",
        "--link", "#{server.container_name}:postgres", cluster.image.name,
        "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'")
    end
  end

  task :create_database, [:domain, :database_name] => :ensure_setup do |t, args|
    cluster = @cluster
    database = cluster.databases.select { |d| d.name == args.database_name }.first
    server = cluster.servers.select { |s| s.domain == args.domain }.first
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

  task :grant_database, [:domain, :database_name] => :ensure_setup do |t, args|
    cluster = @cluster
    database = cluster.databases.select { |d| d.name == args.database_name }.first
    server = cluster.servers.select { |s| s.domain == args.domain }.first
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

  task :link_keys, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      as "root" do
        inner_server_crt = "#{cluster.image.data_path}/server.crt"
        outer_server_crt = "#{server.data_path}/server.crt"
        unless test "[", "-f", outer_server_crt, "]"
          execute("docker", "run",
            "--rm", "--user", "root", "--entrypoint", "/bin/ln",
            "--volume", "#{server.data_path}:#{cluster.image.data_path}:rw",
            cluster.image.name, "-s", "/etc/ssl/certs/ssl-cert-snakeoil.pem", inner_server_crt
          )
          execute("chown", "root.", outer_server_crt)
        end
        inner_server_key = "#{cluster.image.data_path}/server.key"
        outer_server_key = "#{server.data_path}/server.key"
        unless test "[", "-f", outer_server_key, "]"
          execute("docker", "run",
            "--rm", "--user", "root", "--entrypoint", "/bin/ln",
            "--volume", "#{server.data_path}:#{cluster.image.data_path}:rw",
            cluster.image.name, "-s", "/etc/ssl/private/ssl-cert-snakeoil.key", inner_server_key
          )
          execute("chown", "root.", outer_server_key)
        end
      end
    end
  end

  private

    def stay_running_message(server)
      "Container #{server.container_name} on #{server.domain} did not stay running more than 2 seconds"
    end

    def files_in_data_path?(server)
      test("[", "\"$(ls", "-A", "#{server.data_path})\"", "]")
    end

    def config_file_differs?(cluster, server, config_file)
      generated_config_file = generate_config_file(cluster, server, config_file)
      as 'root' do
        if test("[", "-f", "#{server.conf_path}/#{config_file}", "]")
          capture("cat", "#{server.conf_path}/#{config_file}") != generated_config_file
        else
          true
        end
      end
    end

    def generate_config_file(cluster, server, config_file)
      @cluster      = cluster # needed for ERB
      @server       = server  # needed for ERB
      template_path = File.expand_path("templates/#{config_file}.erb")
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
      test "docker", "inspect", server.container_name, ">", "/dev/null"
    end

    def container_is_running?(server)
      (capture "docker", "inspect",
        "--format='{{.State.Running}}'",
        server.container_name).strip == "true"
    end

    def confirm_database_overwrite?(server, database)
      warn "Database #{database.name} already exists on #{server.domain}"
      warn "If you continue, you must be positive you want to delete and recreate the database on " +
        "#{server.domain} in the container #{server.container_name} which " +
        "stores it's data in #{server.data_path} on the host."
      warn "Are you positive(Y/N)?"
      STDOUT.flush
      case STDIN.gets.chomp.upcase
      when "Y"
        true
      when "N"
        false
      else
        warn "Please enter Y or N"
        confirm_database_overwrite?(server, database)
      end
    end
end
