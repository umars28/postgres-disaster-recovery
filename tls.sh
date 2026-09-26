mkdir -p certs/ca certs/minio
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout certs/ca/ca.key -out certs/ca/ca.crt -subj "/CN=pitr-lab-ca"
openssl req -newkey rsa:2048 -nodes \
  -keyout certs/minio/private.key -out certs/minio/minio.csr -subj "/CN=minio"
openssl x509 -req -in certs/minio/minio.csr -days 365 \
  -CA certs/ca/ca.crt -CAkey certs/ca/ca.key -CAcreateserial \
  -out certs/minio/public.crt \
  -extfile <(printf "subjectAltName=DNS:minio,DNS:localhost")
rm certs/minio/minio.csr