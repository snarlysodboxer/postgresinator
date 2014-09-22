class PostgresClusters
  # TODO: change this to multiple methods that can reference each other
  def self.settings
    {
      "clusters"                    => [
        {
          # image_name stays same for each cluster, => postgres only replicates between same versions
          "image_name"                  => "localhost:5000/ubuntu/postgresql-9.1:0.0.0",

          "config_files"                => ["postgres.conf", "pg_hba.conf"],

          "servers"                     => [
            {
              # only one master per cluster
              "master"                      => true,
              "domain"                      => "client.example.com",

              # TODO: make volume commands programmatically
              "docker_run_command"          => [
                "--detach", "--tty", "--user", "postgres",
                "--name", "client.example.com-postgres-master",
                "--volume", "/client.example.com-production-postgres-master-data:/var/lib/postgresql/data:rw",
                "--volume", "/client.example.com-production-postgres-master-conf/pg_hba.conf:/etc/postgresql/9.1/main/pg_hba.conf:rw",
                "--volume", "/client.example.com-production-postgres-master-conf/postgresql.conf:/etc/postgresql/9.1/main/postgresql.conf:rw",
                "--volume", "/client.example.com-production-postgres-master-conf/start.sh:/start.sh:rw",
                "--expose", "5432",
                "--publish", "127.0.0.1:5432:5432",
                "stackbrew/postgres:9.1.14"
              ]
            },
            {
              "master"                      => false,
              "domain"                      => "client-other.example.com",
              "container_name"              => "production-postgres-slave",
              "docker_run_command"          => [
                "--detach", "--tty", "--user", "postgres",
                "--name", "client.example.com-postgres-slave",
                "--volume", "/client.example.com-postgres-slave-data:/var/lib/postgresql/data:rw",
                "--volume", "/client.example.com-postgres-slave-conf/pg_hba.conf:/etc/postgresql/9.1/main/pg_hba.conf:rw",
                "--volume", "/client.example.com-postgres-slave-conf/postgresql.conf:/etc/postgresql/9.1/main/postgresql.conf:rw",
                "--expose", "5432",
                "--publish", "127.0.0.1:5433:5432",
                "stackbrew/postgres:9.1.14"
              ]
            }
          ]
        }
      ]
    }
  end
end
