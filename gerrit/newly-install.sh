#!/bin/bash

id gerrit | grep "1000"
if [ $? != 0 ]; then
  echo "Please create user with id 1000"
  exit 1
fi

# clear data first (if exist)
docker rm -f gerrit postgres; rm -rf /srv/gerrit/{etc,git,index,cache}/*; rm -rf /srv/postgres/*
mkdir -p /srv/gerrit/{etc,git,index,cache}
cp -f etc_gerrit.config /srv/gerrit/etc/gerrit.config
cp -f etc_secure.config /srv/gerrit/etc/secure.config
chown gerrit:gerrit -R /srv/gerrit

# start up postgres
docker-compose up -d postgres

sleep 10s

# init gerrit
sed -i "s/#entrypoint/entrypoint/g" docker-compose.yml
docker-compose up gerrit

# start gerrit
sed -i "s/entrypoint/#entrypoint/g" docker-compose.yml
docker-compose up -d gerrit


#sed -i "s/gerrit.trustchain.com:8080/gerrit.trustchain.com/g" /srv/gerrit/etc/gerrit.config
#chown gerrit:gerrit -R /srv/gerrit
#docker exec -ti gerrit /var/gerrit/bin/gerrit.sh restart
