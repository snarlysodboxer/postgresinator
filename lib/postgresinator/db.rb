namespace :db do

  #desc "Idempotently setup one or more databases."
  task :setup => :ensure_setup do
    on roles(:db) do |host|
      fetch(:postgres_databases).each do |database|
        unless pg_role_exists?(database[:db_role])
          info "Creating role #{database[:db_role]} on #{host}"
          pg_create_role(database[:db_role], database[:pass])
        end
        unless pg_database_exists?(database[:name])
          info "Creating database #{database[:name]} on #{host}"
          pg_create_database(database)
          pg_grant_database(database)
        end
      end
    end
  end

  desc "Restore 'dump_file' in /tmp on the master server into 'database_name'."
  task :restore, [:dump_file, :database_name]  => :ensure_setup do |t, args|
    on roles(:db) do
      if pg_database_empty?(args.database_name)
        clean = ""
      else
        pg_confirm_database_overwrite?(args.database_name) ? clean = "--clean" : exit(0)
      end
      execute("docker", "run", "--rm",
        "--volume", "/tmp:/tmp:rw",
        "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
        "--entrypoint", "/bin/bash",
        fetch(:postgres_image_name),
        "-c", "'/usr/bin/pg_restore", "-U", "postgres", clean,
        "-d", args.database_name, "-F", "tar", "-v", "/tmp/#{args.dump_file}'"
      )
    end
  end

  desc "Dump 'database_name' into /tmp/'dump_file' on the master server."
  task :dump, [:dump_file, :database_name]  => :ensure_setup do |t, args|
    on roles(:db) do
      pg_confirm_file_overwrite?(args.dump_file) if file_exists?("/tmp/#{args.dump_file}")
      execute("docker", "run", "--rm",
        "--volume", "/tmp:/tmp:rw",
        "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
        "--entrypoint", "/bin/bash",
        fetch(:postgres_image_name),
        "-c", "'/usr/bin/pg_dump", "-U", "postgres", "-F", "tar",
        "-v", database[:name], ">", "/tmp/#{args.dump_file}'"
      )
    end
  end

  desc "Print the command to enter psql interactive mode on 'domain'."
  task :print_interactive, [:domain] => :ensure_setup do |t, args|
    run_locally do
      info "You can paste the following command into a terminal on #{host} to enter psql interactive mode for #{host.properties.postgres_container_name}:"
      info "docker run --rm --interactive --tty --volume #{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw --entrypoint /bin/bash #{fetch(:postgres_image_name)} -lic '/usr/bin/psql -U postgres'"
    end
  end

  desc "List the databases from the master."
  task :list => :ensure_setup do |t, args|
    on roles(:db) do
      execute("docker", "run", "--rm",
        "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
        "--entrypoint", "/bin/bash",
        fetch(:postgres_image_name),
        "-c", "'/usr/bin/psql", "-U", "postgres",
        "-a", "-c", "\"\\l\"'")
    end
  end

  desc "List the roles from the master."
  task :list_roles => :ensure_setup do |t, args|
    on roles(:db) do
      execute("docker", "run", "--rm",
        "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
        "--entrypoint", "/bin/bash",
        fetch(:postgres_image_name),
        "-c", "'/usr/bin/psql", "-U", "postgres",
        "-c", "\"\\du\"'")
    end
  end

  desc "Show the streaming replication status of each instance."
  task :streaming => :ensure_setup do
    on roles(:db) do
      info "Streaming status of #{host.properties.postgres_container_name} on #{host}:"
      execute("echo", "\"SELECT", "*", "FROM", "pg_stat_replication;\"", "|",
        "docker", "run", "--rm", "--interactive",
        "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
        "--entrypoint", "/bin/bash",
        fetch(:postgres_image_name),
        "-c", "'/usr/bin/psql", "-U", "postgres", "-xa'")
    end
    on roles(:db_slave) do
      info "Streaming status of #{host.properties.postgres_container_name} on #{host}:"
      execute("echo", "\"SELECT", "now()", "-", "pg_last_xact_replay_timestamp()",
        "AS", "replication_delay;\"", "|",
        "docker", "run", "--rm", "--interactive",
        "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
        "--entrypoint", "/bin/bash",
        fetch(:postgres_image_name),
        "-c", "'/usr/bin/psql", "-U", "postgres'")
    end
  end

  def pg_create_role(db_role, password)
    execute("echo", "\"CREATE", "ROLE", "\\\"#{db_role}\\\"",
      "WITH", "LOGIN", "ENCRYPTED", "PASSWORD", "'#{password}'",
      "REPLICATION", "CREATEDB;\"", "|",
      "docker", "run", "--rm", "--interactive",
      "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
      "--entrypoint", "/bin/bash",
      fetch(:postgres_image_name),
      "-c", "'/usr/bin/psql", "-U", "postgres'")
  end

  def pg_create_database(database)
    execute("echo", "\"CREATE", "DATABASE", "\\\"#{database[:name]}\\\"",
      "WITH", "OWNER", "\\\"#{database[:db_role]}\\\"", "TEMPLATE",
      "template0", "ENCODING", "'UTF8';\"", "|",
      "docker", "run", "--rm", "--interactive",
      "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
      "--entrypoint", "/bin/bash",
      fetch(:postgres_image_name),
      "-c", "'/usr/bin/psql", "-U", "postgres'")
  end

  def pg_grant_database(database)
    execute("echo", "\"GRANT", "ALL", "PRIVILEGES", "ON", "DATABASE",
      "\\\"#{database[:name]}\\\"", "to", "\\\"#{database[:db_role]}\\\";\"", "|",
      "docker", "run", "--rm", "--interactive",
      "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
      "--entrypoint", "/bin/bash",
      fetch(:postgres_image_name),
      "-c", "'/usr/bin/psql", "-U", "postgres'")
  end

  def pg_role_exists?(db_role)
    test("echo", "\"SELECT", "*", "FROM", "pg_user", "WHERE", "usename", "=", "'#{db_role}';\"", "|",
      "docker", "run", "--rm", "--interactive",
      "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
      "--entrypoint", "/bin/bash",
      fetch(:postgres_image_name),
      "-c", "'/usr/bin/psql", "-U", "postgres'", "|",
      "grep", "-q", "'#{db_role}'")
  end

  def pg_database_exists?(database_name)
    test "docker", "run", "--rm",
      "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
      "--entrypoint", "/bin/bash",
       fetch(:postgres_image_name),
      "-c", "'/usr/bin/psql", "-U", "postgres", "-lqt", "|",
      "cut", "-d\\|", "-f1", "|", "grep", "-w", "#{database_name}'"
  end

  def pg_confirm_file_overwrite?(dump_file)
    warn "A file named #{dump_file} already exists on #{host} in /tmp. If you continue, you will overwrite it."
    set :yes_or_no, "Are you positive?"
    case fetch(:yes_or_no).chomp.downcase
    when "yes"
      true
    when "no"
      false
    else
      warn "Please enter 'yes' or 'no'"
      pg_confirm_file_overwrite?(dump_file)
    end
  end

  def pg_confirm_database_overwrite?(database_name)
    warn "There is already data in #{database_name} on #{host} in the container " +
      "#{host.properties.postgres_container_name} which stores it's data in #{fetch(:postgres_data_path)} on the host."
    warn "If you continue, you must be positive you want to overwrite the existing data."
    set :yes_or_no, "Are you positive?"
    case fetch(:yes_or_no).chomp.downcase
    when "yes"
      true
    when "no"
      false
    else
      warn "Please enter 'yes' or 'no'"
      pg_confirm_database_overwrite?(database_name)
    end
  end

  def pg_database_empty?(database_name)
    test("docker", "run", "--rm",
      "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
      "--entrypoint", "/bin/bash", fetch(:postgres_image_name), "-lc",
      "'/usr/bin/psql", "-U", "postgres", "-d", database_name,
      "-c", "\"\\dt\"", "|", "grep", "-qi", "\"no relations found\"'")
  end
end
