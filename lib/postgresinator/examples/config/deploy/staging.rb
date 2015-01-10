set  :domain,                   "my-app.example.com"
set  :deploy_username,          "deployer"
set  :user_host,                "#{fetch(:deploy_username)}@#{fetch(:domain)}"

role :app,                      fetch(:user_host)
role :web,                      fetch(:user_host)
role :db,                       fetch(:user_host)

set :postgres_image_name,       "snarlysodboxer/postgresql:0.0.1"
set :postgres_config_files,     ["postgresql.conf", "pg_hba.conf", "recovery.conf"]
set :postgres_data_path,        "/var/lib/postgresql/9.1/main"
set :postgres_conf_path,        "/etc/postgresql/9.1/main"
set :postgres_sock_path,        "/var/run/postgresql"
set :postgres_uid,              "101"
set :postgres_gid,              "104"
set :databases,                 [
  {
    "name"                        => "client",
    "db_role"                     => "client",
    "pass"                        => "client"
  }
]
set :servers,                   -> {
  [
    {
      "master"                      => true,
      "domain"                      => fetch(:domain),
      "port"                        => "5432"
    },
    {
      "master"                      => false,
      "domain"                      => "my-app-other.example.com",
      "port"                        => "5433"
    }
  ]
}
