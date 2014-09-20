class PostgresClusters
  def self.settings
    {
      "clusters"                    => [
        {
          # image_name stays same for each cluster, => postgres only replicates between same versions
          "image_name"                  => "stackbrew/postgres:9.1.14",

          "config_files"                => ["postgres.conf", "pg_hba.conf"],

          "servers"                     => [
            {
              # only one master per cluster
              "master"                      => true,
              "domain"                      => "client.example.com",

              # container_name must be unique per docker daemon
              "container_name"              => "production-postgres-master",

              # publish:
              #   true  = expose postgres port to 127.0.0.1 on the host, (for use with non-dockerized applications), or
              #   false = for linking to with other docker containers.
              "publish"                     => true,

              # port on host to publish if publishing
              "publish_port"                => "5432"
            },
            {
              "master"                      => false,
              "domain"                      => "client-cp.example.com",
              "container_name"              => "production-postgres-slave",
              "publish"                     => true,
              "publish_port"                => "5433"
            }
          ]
        }
      ]
    }
  end
end
