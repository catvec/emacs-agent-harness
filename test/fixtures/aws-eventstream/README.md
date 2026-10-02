# AWS event stream test vectors

Copied unchanged from the AWS SDK for Go v2,
`aws/protocol/eventstream/testdata/`
(https://github.com/aws/aws-sdk-go-v2), licensed under the Apache
License 2.0.

- `encoded/positive/NAME` is a binary event stream message and
  `decoded/positive/NAME` its expected decoding as JSON (string and
  byte array header values and the payload in base64).
- `encoded/negative/NAME` is a corrupted message and
  `decoded/negative/NAME` the error a decoder must report.
