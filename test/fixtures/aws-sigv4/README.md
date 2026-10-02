# AWS Signature Version 4 test suite

Copied unchanged from `tests/aws-signing-test-suite/v4/` of aws-c-auth
(https://github.com/awslabs/aws-c-auth), the AWS Signature Version 4
test suite, licensed under the Apache License 2.0.

Each directory is one case:

- `request.txt`: the HTTP request to sign;
- `context.json`: the credentials, region, service and time to sign with;
- `header-canonical-request.txt`, `header-string-to-sign.txt` and
  `header-signature.txt`: the expected intermediate results and signature;
- `header-signed-request.txt`: the request with its signature headers.
