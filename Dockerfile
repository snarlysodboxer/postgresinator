# vi: ft=config
FROM ubuntu:12.04
MAINTAINER david amick <docker@davidamick.com>

RUN /bin/bash -l -c "apt-get update -qq && apt-get install -qy postgresql-9.1 libpq-dev postgresql-contrib nodejs rsync"
RUN /bin/bash -l -c "/etc/init.d/postgresql start && /etc/init.d/postgresql stop"

EXPOSE 5432
USER postgres
ENTRYPOINT ["/usr/lib/postgresql/9.1/bin/postgres"]
CMD ["-D", "/var/lib/postgresql/9.1/main", "-c", "config_file=/etc/postgresql/9.1/main/postgresql.conf"]
