#!/bin/bash

set -x
set -euo pipefail

openssl genrsa -aes256 -out key.pem -passout pass:temp 2048
openssl rsa -in key.pem -passin pass:temp -out key.pem
openssl req -x509 -key key.pem -out cert.pem -days 10950 -new -subj "/CN=localhost/"
