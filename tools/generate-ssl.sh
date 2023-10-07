#!/bin/bash

# 生成证书的信息
COUNTRY="US"
STATE="Los Angeles"
LOCALITY="Los Angeles"
ORGANIZATION="Your Organization"
ORG_UNIT="Your Organizational Unit"
COMMON_NAME="example.com"
EMAIL="admin@example.com"

# 生成私钥
openssl genrsa -out $COMMON_NAME.key 4096

# 生成 CSR
openssl req -new \
    -key $COMMON_NAME.key \
    -out $COMMON_NAME.csr \
    -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/OU=$ORG_UNIT/CN=$COMMON_NAME/emailAddress=$EMAIL"

# 生成自签名证书
openssl x509 -req \
    -days 36500 \
    -in $COMMON_NAME.csr \
    -signkey $COMMON_NAME.key \
    -out $COMMON_NAME.crt

# 清理 CSR 文件
rm $COMMON_NAME.csr

# 输出结果
echo "SSL 证书已创建：$COMMON_NAME.crt"
echo "SSL 私钥已创建：$COMMON_NAME.key"
