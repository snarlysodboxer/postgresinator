class PostgresCluster
  def self.settings
    {
      "image"                       => {
        "name"                        => "snarlysodboxer/postgresql:0.0.1",
        "config_files"                => ["postgresql.conf", "pg_hba.conf", "recovery.conf"],
        "data_path"                   => "/var/lib/postgresql/9.1/main",
        "conf_path"                   => "/etc/postgresql/9.1/main",
        "sock_path"                   => "/var/run/postgresql",
        "postgres_uid"                => "101",
        "postgres_gid"                => "104"

      },
      "databases"                   => [
        {
          "name"                        => "client",
          "role"                        => "client",
          "pass"                        => "client"
        }
      ],
      "servers"                     => [
        {
          "master"                      => true,
          "domain"                      => "client.example.com",
          "port"                        => "5432"
        },
        {
          "master"                      => false,
          "domain"                      => "client-other.example.com",
          "port"                        => "5433"
        }
      ]
    }
  end
end
