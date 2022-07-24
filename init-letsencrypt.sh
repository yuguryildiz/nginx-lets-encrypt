#!/bin/bash

if ! [ -x "$(command -v docker-compose)" ]; then
  echo 'Error: docker-compose is not installed.' >&2
  exit 1
fi

while [ -z "$r_domains" ]
do
    echo 'Please enter domains (Seperated by a space):'
    read r_domains
    echo
done

while [ -z "$email" ]
do
    echo 'Please enter e-mail address:'
    read email
    echo
done

IFS=' ' read -r -a domains <<< "$r_domains"
rsa_key_size=4096
data_path="./data/certbot"
nginx_conf_path="./data/nginx/conf"
staging=0 # Set to 1 if you're testing your setup to avoid hitting request limits

if [ -d "$data_path" ]; then
  read -p "Existing data found for $domains. Continue and replace existing certificate? (y/N) " decision
  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
    exit
  fi
fi

if [ ! -e "$data_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$data_path/conf/ssl-dhparams.pem" ]; then
  echo "### Downloading recommended TLS parameters ###"
  mkdir -p "$data_path/conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$data_path/conf/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$data_path/conf/ssl-dhparams.pem"
  echo
fi

mkdir -p $nginx_conf_path

for domain in "${domains[@]}"; do

  echo "Processing for $domain"

  conf_file_name="$nginx_conf_path/$domain.conf"

  echo "### Copying nginx http configuration file ###"
  cp -v http.conf $conf_file_name
  echo "### Copied nginx http configuration file > $conf_file_name ###"
  echo "### Replacing nginx http configuration file ###"
  sed -i "" "s/{{domain}}/$domain/g" $conf_file_name

  echo "### Creating dummy certificate for $domain ###"
  path="/etc/letsencrypt/live/$domain"
  mkdir -p "$data_path/conf/live/$domain"
  docker-compose run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1\
      -keyout '$path/privkey.pem' \
      -out '$path/fullchain.pem' \
      -subj '/CN=localhost'" certbot
  echo

  echo "### Starting nginx ###"
  docker-compose up --force-recreate -d nginx
  echo

  echo "### Deleting dummy certificate for $domain ###"
  docker-compose run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$domain && \
  rm -Rf /etc/letsencrypt/archive/$domain && \
  rm -Rf /etc/letsencrypt/renewal/$domain.conf" certbot
  echo

  echo "### Requesting Let's Encrypt certificate for $domain ###"
  domain_args="-d $domain"

  case "$email" in
    "") email_arg="--register-unsafely-without-email" ;;
    *) email_arg="--email $email" ;;
  esac

  if [ $staging != "0" ]; then staging_arg="--staging"; fi  
  docker-compose run --rm --entrypoint "\
    certbot certonly --webroot -w /var/www/certbot \
      $staging_arg \
      $email_arg \
      $domain_args \
      --rsa-key-size $rsa_key_size \
      --agree-tos \
      --force-renewal" certbot
  echo  
  echo "### Removing nginx ###"
  # docker-compose exec nginx nginx -s reload
  docker-compose down

  echo "### Copying nginx https configuration file ###"
  cp -v https.conf $conf_file_name
  echo "### Copied nginx https configuration file > $conf_file_name ###"
  echo "### Replacing https configuration file ###"
  sed -i "" "s/{{domain}}/$domain/g" $conf_file_name

done