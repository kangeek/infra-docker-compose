#!/bin/sh

# create self-signed server certificate:

read -p "Enter your domain [xxx.peony.dev]: " DOMAIN

echo "Create server key..."

openssl genrsa -des3 -out $DOMAIN.key 1024

echo "Create server certificate signing request..."

SUBJECT="/C=CN/ST=ShanDong/L=Jinan/O=Peony/OU=TechDept/CN=$DOMAIN"

openssl req -new -subj $SUBJECT -key $DOMAIN.key -out $DOMAIN.csr

echo "Remove password..."

mv $DOMAIN.key $DOMAIN.origin.key
openssl rsa -in $DOMAIN.origin.key -out $DOMAIN.key

echo "Sign SSL certificate..."

openssl x509 -req -days 3650 -in $DOMAIN.csr -signkey $DOMAIN.key -out $DOMAIN.crt

echo "TODO:"
#echo "Copy $DOMAIN.crt to /etc/nginx/ssl/$DOMAIN.crt"
#echo "Copy $DOMAIN.key to /etc/nginx/ssl/$DOMAIN.key"
echo "Add configuration in nginx:"
echo "server {"
echo "    ..."
echo "    listen 443 ssl;"
echo "    ssl_certificate     /etc/nginx/ssl/$DOMAIN.crt;"
echo "    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;"
echo "}"
echo "Then restart nginx container."
