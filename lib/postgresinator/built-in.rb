set :postgres_templates_path,           "templates/postgres"
set :postgres_config_files,             ["postgresql.conf", "pg_hba.conf"]
set :postgres_recovery_conf,            ["recovery.conf"]
set :postgres_root_path,                -> { shared_path.join('postgres', fetch(:stage).to_s) }
set :postgres_data_path,                -> { fetch(:postgres_root_path).join('data') }
set :postgres_config_path,              -> { fetch(:postgres_root_path).join('conf') }
set :postgres_socket_path,              -> { fetch(:postgres_root_path).join('run') }
set :postgres_recovery_conf,            -> { "#{fetch(:postgres_data_path)}/recovery.conf" }
set :postgres_ssl_key,                  -> { "#{fetch(:postgres_data_path)}/server.key" }
set :postgres_ssl_csr,                  -> { "#{fetch(:postgres_data_path)}/server.csr" }
set :postgres_ssl_crt,                  -> { "#{fetch(:postgres_data_path)}/server.crt" }
set :postgres_entrypoint,               -> { "/usr/lib/postgresql/#{fetch(:postgres_version)}/bin/postgres" }
set :postgres_main_dir,                 -> { "/var/lib/postgresql/#{fetch(:postgres_version)}/main/" }

def pg_run(host)
  execute(
    "docker", "run", "--detach", "--tty", "--user", "postgres",
    "--name", host.properties.postgres_container_name,
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--expose", 5432,
    "--publish", "0.0.0.0:#{host.properties.postgres_port}:5432",
    "--restart", "always",
    # TODO switch to universal entrypoints instead of version specific ones
    "--entrypoint", fetch(:postgres_entrypoint),
    fetch(:postgres_image_name),
    "-D", fetch(:postgres_data_path),
    "-c", "config_file=#{fetch(:postgres_config_path)}/postgresql.conf"
  )
end
def pg_init(host)
  execute(
    "docker", "run", "--rm", "--user", "root",
    "--volume", "#{fetch(:postgres_data_path)}:/postgresql-data:rw",
    "--entrypoint", "/usr/bin/rsync",
    fetch(:postgres_image_name), "-ah", fetch(:postgres_main_dir), "/postgresql-data/"
  )
end
def pg_replicate(host)
  execute(
    "docker", "run", "--rm", "--user", "postgres",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/usr/bin/pg_basebackup",
    fetch(:postgres_image_name),
    "-w", "-h", fetch(:domain), "-p", fetch(:master_container_port),
    "-U", "replicator", "-D", fetch(:postgres_data_path), "-v", "-x"
  )
end
def pg_ssl_key(host)
  execute(
    "docker", "run", "--rm", "--user", "root",
    "--entrypoint", "/usr/bin/openssl",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    fetch(:postgres_image_name), "req", "-nodes", "-newkey", "rsa:2048",
    "-keyout", fetch(:postgres_ssl_key),
    "-out", fetch(:postgres_ssl_csr),
    "-subj", "\"/C=US/ST=Oregon/L=Portland/O=My Company/OU=Operations/CN=localhost\""
  )
end
def pg_ssl_crt(host)
  execute(
    "docker", "run", "--rm", "--user", "root",
    "--entrypoint", "/usr/bin/openssl",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    fetch(:postgres_image_name), "req", "-x509", "-text",
    "-in", fetch(:postgres_ssl_csr),
    "-key", fetch(:postgres_ssl_key),
    "-out", fetch(:postgres_ssl_crt)
  )
end
def pg_restore(host, args, clean)
  execute(
    "docker", "run", "--rm",
    "--volume", "/tmp:/tmp:rw",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/bin/bash",
    fetch(:postgres_image_name),
    "-c", "'/usr/bin/pg_restore", "-U", "postgres",
    "--host", fetch(:postgres_socket_path), clean,
    "-d", args.database_name, "-F", "tar", "-v", "/tmp/#{args.dump_file}'"
  )
end
def pg_dump(host, args)
  execute(
    "docker", "run", "--rm",
    "--volume", "/tmp:/tmp:rw",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/bin/bash",
    fetch(:postgres_image_name),
    "-c", "'/usr/bin/pg_dump", "-U", "postgres",
    "--host", fetch(:postgres_socket_path), "-F", "tar",
    "-v", args.database_name, ">", "/tmp/#{args.dump_file}'"
  )
end
def pg_interactive(host)
  [
    "ssh", "-t", "#{host}", "\"docker", "run", "--rm", "--interactive", "--tty",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/bin/bash",
    "#{fetch(:postgres_image_name)}",
    "-lic", "'/usr/bin/psql", "-U", "postgres",
    "--host", "#{fetch(:postgres_socket_path)}'\""
  ].join(' ')
end
def pg_interactive_print(host)
  [
    "docker", "run", "--rm", "--interactive", "--tty",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/bin/bash",
    "#{fetch(:postgres_image_name)}",
    "-lic", "'/usr/bin/psql", "-U", "postgres",
    "--host", "#{fetch(:postgres_socket_path)}'"
  ].join(' ')
end
def pg_list_databases(host)
  capture(
    "docker", "run", "--rm",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/bin/bash",
    fetch(:postgres_image_name),
    "-c", "'/usr/bin/psql", "-U", "postgres",
    "--host", fetch(:postgres_socket_path),
    "-a", "-c", "\"\\l\"'"
  ).lines.each { |l| info l }
end
def pg_list_roles(host)
  capture(
    "docker", "run", "--rm",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/bin/bash",
    fetch(:postgres_image_name),
    "-c", "'/usr/bin/psql", "-U", "postgres",
    "--host", fetch(:postgres_socket_path),
    "-c", "\"\\du\"'"
  ).lines.each { |l| info l }
end
def pg_streaming_master(host)
  capture(
    "echo", "\"SELECT", "*", "FROM", "pg_stat_replication;\"", "|",
    "docker", "run", "--rm", "--interactive",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/bin/bash",
    fetch(:postgres_image_name),
    "-c", "'/usr/bin/psql", "-U", "postgres", "-xa",
    "--host", "#{fetch(:postgres_socket_path)}'"
  ).lines.each { |l| info l }
end
def pg_streaming_slave(host)
  capture(
    "echo", "\"SELECT", "now()", "-", "pg_last_xact_replay_timestamp()",
    "AS", "replication_delay;\"", "|",
    "docker", "run", "--rm", "--interactive",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/bin/bash",
    fetch(:postgres_image_name),
    "-c", "'/usr/bin/psql", "-U", "postgres",
    "--host", "#{fetch(:postgres_socket_path)}'"
  ).lines.each { |l| info l }
end
def pg_create_role(db_role, password)
  execute(
    "echo", "\"CREATE", "ROLE", "\\\"#{db_role}\\\"",
    "WITH", "LOGIN", "ENCRYPTED", "PASSWORD", "'#{password}'",
    "REPLICATION", "CREATEDB;\"", "|",
    "docker", "run", "--rm", "--interactive",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/bin/bash",
    fetch(:postgres_image_name),
    "-c", "'/usr/bin/psql", "-U", "postgres",
    "--host", "#{fetch(:postgres_socket_path)}'"
  )
end
def pg_create_database(database)
  execute(
    "echo", "\"CREATE", "DATABASE", "\\\"#{database[:name]}\\\"",
    "WITH", "OWNER", "\\\"#{database[:db_role]}\\\"", "TEMPLATE",
    "template0", "ENCODING", "'UTF8';\"", "|",
    "docker", "run", "--rm", "--interactive",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/bin/bash",
    fetch(:postgres_image_name),
    "-c", "'/usr/bin/psql", "-U", "postgres",
    "--host", "#{fetch(:postgres_socket_path)}'"
  )
end
def pg_grant_database(database)
  execute(
    "echo", "\"GRANT", "ALL", "PRIVILEGES", "ON", "DATABASE",
    "\\\"#{database[:name]}\\\"", "to", "\\\"#{database[:db_role]}\\\";\"", "|",
    "docker", "run", "--rm", "--interactive",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/bin/bash",
    fetch(:postgres_image_name),
    "-c", "'/usr/bin/psql", "-U", "postgres",
    "--host", "#{fetch(:postgres_socket_path)}'"
  )
end
def pg_role_exists?(db_role)
  test(
    "echo", "\"SELECT", "*", "FROM", "pg_user",
    "WHERE", "usename", "=", "'#{db_role}';\"", "|",
    "docker", "run", "--rm", "--interactive",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/bin/bash",
    fetch(:postgres_image_name),
    "-c", "'/usr/bin/psql", "-U", "postgres",
    "--host", "#{fetch(:postgres_socket_path)}'", "|",
    "grep", "-qw", "'#{db_role}'"
  )
end
def pg_database_exists?(database_name)
  test(
    "docker", "run", "--rm",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/bin/bash",
     fetch(:postgres_image_name),
    "-c", "'/usr/bin/psql", "-U", "postgres",
    "--host", fetch(:postgres_socket_path), "-lqt", "|",
    "cut", "-d\\|", "-f1", "|", "grep", "-qw", "#{database_name}'"
  )
end
def pg_database_empty?(database_name)
  test(
    "docker", "run", "--rm", "--tty",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--entrypoint", "/bin/bash", fetch(:postgres_image_name), "-lc",
    "'/usr/bin/psql", "-U", "postgres", "-d", database_name,
    "--host", fetch(:postgres_socket_path),
    "-c", "\"\\dt\"", "|", "grep", "-qi", "\"no relations found\"'"
  )
end
