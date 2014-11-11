## For a standard Ubuntu 12.04 Nginx Docker image you should only
##  need to change the following values to get started:

set :domain,                    "my-app.example.com"
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



## The values below may be commonly changed to match specifics
##  relating to a particular Docker image or setup:



## The values below are not meant to be changed and shouldn't
##  need to be under the majority of circumstances:

