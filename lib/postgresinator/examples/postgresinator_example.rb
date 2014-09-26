class PostgresCluster
  def self.settings
    {
      "image"                       => {
        "name"                        => "localhost:5000/ubuntu/postgresql-9.1:0.0.1",
        "config_files"                => ["postgresql.conf", "pg_hba.conf"],
        "data_path"                   => "/var/lib/postgresql/9.1/main",
        "conf_path"                   => "/etc/postgresql/9.1/main"
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
