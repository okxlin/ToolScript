#!/bin/bash

# 提示用户输入服务器IP地址
read -p "请输入服务器的IP地址 (例如：192.168.1.100): " server_ip

# 命名存储证书的文件夹
cert_dir="frp-certs-$server_ip"

# 检查是否存在旧的文件夹，如果存在，向用户进行确认
if [ -d "$cert_dir" ]; then
  read -p "发现旧的文件夹 '$cert_dir'，是否确认删除并继续 (y/n)? " confirm
  if [ "$confirm" = "y" ]; then
    rm -rf "$cert_dir"/*  # 删除文件夹中的所有内容，但不删除文件夹本身
  else
    echo "操作已取消。"
    exit 1
  fi
fi

# 创建存储证书的文件夹
mkdir -p "$cert_dir"

# 创建openssl配置文件
cat > "$cert_dir/openssl.cnf" << EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
x509_extensions = usr_cert
[ req ]
default_bits        = 2048
default_md          = sha256
default_keyfile     = privkey.pem
distinguished_name  = req_distinguished_name
attributes          = req_attributes
x509_extensions     = v3_ca
string_mask         = utf8only
[ req_distinguished_name ]
[ req_attributes ]
[ usr_cert ]
basicConstraints       = CA:FALSE
nsComment              = "OpenSSL Generated Certificate"
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = CA:true
EOF

# 生成根CA证书
openssl genrsa -out "$cert_dir/ca.key" 2048
openssl req -x509 -new -nodes -key "$cert_dir/ca.key" -subj "/CN=example.ca.com" -days 5000 -out "$cert_dir/ca.crt"

# 生成frps证书
openssl genrsa -out "$cert_dir/server.key" 2048
openssl req -new -sha256 -key "$cert_dir/server.key" \
    -subj "/C=XX/ST=DEFAULT/L=DEFAULT/O=DEFAULT/CN=server.com" \
    -reqexts SAN \
    -config <(cat "$cert_dir/openssl.cnf" <(printf "\n[SAN]\nsubjectAltName=DNS:localhost,IP:$server_ip")) \
    -out "$cert_dir/server.csr"
openssl x509 -req -days 3650 -sha256 \
    -in "$cert_dir/server.csr" -CA "$cert_dir/ca.crt" -CAkey "$cert_dir/ca.key" -CAcreateserial \
    -extfile <(printf "subjectAltName=DNS:localhost,IP:$server_ip") \
    -out "$cert_dir/server.crt"

# 生成frpc证书
openssl genrsa -out "$cert_dir/client.key" 2048
openssl req -new -sha256 -key "$cert_dir/client.key" \
    -subj "/C=XX/ST=DEFAULT/L=DEFAULT/O=DEFAULT/CN=client.com" \
    -reqexts SAN \
    -config <(cat "$cert_dir/openssl.cnf" <(printf "\n[SAN]\nsubjectAltName=DNS:client.com,DNS:example.client.com")) \
    -out "$cert_dir/client.csr"
openssl x509 -req -days 3650 -sha256 \
    -in "$cert_dir/client.csr" -CA "$cert_dir/ca.crt" -CAkey "$cert_dir/ca.key" -CAcreateserial \
    -extfile <(printf "subjectAltName=DNS:client.com,DNS:example.client.com") \
    -out "$cert_dir/client.crt"

# 删除不再需要的临时文件
rm "$cert_dir/server.csr" "$cert_dir/client.csr" "$cert_dir/openssl.cnf" "$cert_dir/ca.srl"

# 提示证书文件创建完毕
echo "证书文件生成完毕。"
echo "存储在目录: $cert_dir"
