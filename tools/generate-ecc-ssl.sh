#!/bin/bash

# 提示用户输入域名或IP
read -p "请输入域名或IP: " name

# 提示用户输入SSL证书的有效期（默认为100年）
read -p "请输入SSL证书有效期天数（默认为100年，即36500天）: " ssl_days
ssl_days=${ssl_days:-36500}  # 如果用户未输入，则使用默认值36500天（100年）

# 检查用户输入是否为IP地址
if [[ $name =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  subject_alt_name="IP:${name}"
else
  subject_alt_name="DNS:${name}"
fi

# 生成的文件夹名称，添加"ECC"标志
cert_dir="${name}-ssl-ecc"

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

# 创建CA私钥（使用ECDSA算法）
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-521 -out "$cert_dir/CA.key"

# 创建CA自签名证书
openssl req -new -x509 -days "$ssl_days" -key "$cert_dir/CA.key" -out "$cert_dir/CA.crt" -subj "/C=US/ST=California/L=Los Angeles/O=My Organization/CN=${name}"

# 创建证书的ECDSA私钥
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-521 -out "$cert_dir/private.key"

# 提示用户输入 PKCS#12 格式证书密码
read -s -p "请输入 PKCS#12 格式证书密码: " password
echo

# 创建证书请求文件 csr
openssl req -new -key "$cert_dir/private.key" -subj "/C=US/ST=California/L=Los Angeles/O=My Organization/CN=${name}" -sha256 -out "$cert_dir/private.csr"

# 生成 private.ext 文件
cat <<EOF > "$cert_dir/private.ext"
[ req ]
default_bits = 2048
distinguished_name = req_distinguished_name
req_extensions = san
extensions = san

[ req_distinguished_name ]
countryName = US
stateOrProvinceName = California
localityName = Los Angeles
organizationName = My Organization
commonName = ${name}

[SAN]
subjectAltName = ${subject_alt_name}
EOF

# 使用 CSR 文件和 private.ext、以及根证书 CA.crt 创建证书 private.crt
openssl x509 -req -days "$ssl_days" -in "$cert_dir/private.csr" -CA "$cert_dir/CA.crt" -CAkey "$cert_dir/CA.key" -CAcreateserial -sha256 -out "$cert_dir/private.crt" -extfile "$cert_dir/private.ext" -extensions SAN

# 生成 Fullchain 证书文件
cat "$cert_dir/private.crt" "$cert_dir/CA.crt" > "$cert_dir/fullchain.crt"

# 生成 PKCS#12 格式证书文件
openssl pkcs12 -export -out "$cert_dir/certificate.p12" -inkey "$cert_dir/private.key" -in "$cert_dir/private.crt" -certfile "$cert_dir/CA.crt" -passout pass:"$password"

# 删除不再需要的临时文件
rm "$cert_dir/private.csr" "$cert_dir/private.ext" "$cert_dir/CA.srl"

# 提示证书文件创建完毕
echo "ECDSA 证书文件生成完毕。"
echo "存储在目录: $cert_dir"
