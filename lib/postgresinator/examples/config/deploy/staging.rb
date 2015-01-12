set  :domain,                   "my-app.example.com"
set  :deployment_username,      "deployer"

server fetch(:domain),
  :user             => fetch(:deployment_username),
  :roles            => ["app", "web", "db"],
  :postgres_port    => "5432"
server 'my-app-db-slave.example.com',
  :user             => fetch(:deployment_username),
  :roles            => ["db_slave"],
  :postgres_port    => "5433"
server 'my-app-db-slave2.example.com',
  :user             => fetch(:deployment_username),
  :roles            => ["db_slave"],
  :postgres_port    => "5433"
  # only for override, let postgresinator setup postgres_container_name
  #:postgres_container_name => "my_custom_name"

set :postgres_templates_path,   "templates/postgres"

set :postgres_image_name,       "snarlysodboxer/postgresql:0.0.0"
set :postgres_config_files,     ["postgresql.conf", "pg_hba.conf"]
set :postgres_recovery_conf,    ["recovery.conf"]
set :postgres_data_path,        shared_path.join('postgres', 'data')
set :postgres_config_path,      shared_path.join('postgres', 'conf')
set :postgres_socket_path,      shared_path.join('postgres', 'run')

# TODO get uid and gui instead of setting them
set :postgres_uid,              "101"
set :postgres_gid,              "104"

set :postgres_databases,        [
  {
    "name"                        => "client",
    "db_role"                     => "client",
    "pass"                        => "client"
  }
]


set :postgres_docker_run_command,       -> {
  [
    "--detach",   "--tty", "--user", "postgres",
    "--name",     host.properties.container_name,
    "--volume",   "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    "--expose",   "5432",
    "--publish",  "0.0.0.0:#{host.properties.postgres_port}:5432",
    "--restart", "always",
    "--entrypoint", "/usr/lib/postgresql/9.1/bin/postgres",
    fetch(:postgres_image_name),
    "-D", shared_path.join('postgres', 'data'),
    "-c", "config_file=#{shared_path.join('postgres', 'conf', 'postgresql.conf')}"
  ]
}
set :postgres_docker_init_command,      -> {
  [
    "--rm", "--user", "root",
    "--volume", "#{fetch(:postgres_data_path)}:/postgresql-data:rw",
    "--entrypoint", "/usr/bin/rsync",
    fetch(:postgres_image_name), "-ah", "/var/lib/postgresql/9.1/main/", "/postgresql-data/"
  ]
}
set :postgres_docker_replicate_command, -> {
  [
    "--rm", "--user", "postgres",
    "--entrypoint", "/usr/bin/pg_basebackup",
      fetch(:postgres_image_name),
      "-w", "-h", fetch(:domain), "-p", host.properties.postgres_port,
      "-U", "replicator", "-D", fetch(:postgres_data_path), "-v", "-x"
  ]
}
set :postgres_replicator_pass,          "yourpassword"
set :postgres_recovery_conf,            -> { "#{fetch(:postgres_data_path)}/recovery.conf" }
set :postgres_ssl_key,                  -> { "#{fetch(:postgres_data_path)}/server.key" }
set :postgres_ssl_csr,                  -> { "#{fetch(:postgres_data_path)}/server.csr" }
set :postgres_ssl_crt,                  -> { "#{fetch(:postgres_data_path)}/server.crt" }
set :postgres_docker_ssl_csr_command,   -> {
  [
    "--rm", "--user", "root",
    "--entrypoint", "/usr/bin/openssl",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    fetch(:postgres_image_name), "req", "-nodes", "-newkey", "rsa:2048",
    "-keyout", fetch(:postgres_ssl_key),
    "-out", fetch(:postgres_ssl_csr),
    "-subj", "\"/C=US/ST=Oregon/L=Portland/O=My Company/OU=Operations/CN=localhost\""
  ]
}
set :postgres_docker_ssl_crt_command,   -> {
  [
    "--rm", "--user", "root",
    "--entrypoint", "/usr/bin/openssl",
    "--volume", "#{fetch(:deploy_to)}:#{fetch(:deploy_to)}:rw",
    fetch(:postgres_image_name), "req", "-x509", "-text",
    "-in", fetch(:postgres_ssl_csr),
    "-key", fetch(:postgres_ssl_key),
    "-out", fetch(:postgres_ssl_crt)
  ]
}
