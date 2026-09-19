# "Cloud Storage"

_Path: en/system/cloudstorage_

> "S3-compatible object storage with presigned URLs, multipart uploads and ranged reads."

## Table of Contents

- Cloud Storage

## Content

# Cloud Storage

<secondary-label ref="external"/>

S3-compatible object storage with presigned URLs, multipart uploads and ranged reads.



## Entry Kinds


| Kind | Description |
|------|-------------|
| `config.aws` | AWS credentials and region configuration |
| `cloudstorage.s3` | S3 bucket connection |



## AWS Configuration


```yaml
- name: aws_config
  kind: config.aws
  region: ${env:AWS_REGION}
  access_key_id: ${env:AWS_ACCESS_KEY_ID}
  secret_access_key: ${env:AWS_SECRET_ACCESS_KEY}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `region` | string | Yes | AWS region. Supply via `${env:NAME}` when it differs per deployment |
| `access_key_id` | string | No | AWS access key ID (inline or `${env:NAME}`) |
| `secret_access_key` | string | No | AWS secret access key (inline or `${env:NAME}`) |

Credentials resolve from the [environment registry](system/env.md) at decode time. Both `access_key_id` and `secret_access_key` must resolve to non-empty values for static credentials to apply; otherwise the AWS SDK default credential chain is used (IAM roles, instance profiles, etc.).

Requests are signed with AWS Signature Version 4 by the AWS SDK using the resolved credentials. No signing configuration is required.

<note>
Older configurations use a sibling <code>&lt;field&gt;_env</code> directive (<code>region_env</code>, <code>access_key_id_env</code>, <code>secret_access_key_env</code>) that resolves the same way. This form is <b>deprecated</b> — migrate it to the <code>${env:NAME}</code> placeholder shown above.
</note>

<note>
A single <code>config.aws</code> entry can be reused across AWS-backed services. <code>queue.driver.sqs</code> references the same entry via its <code>config:</code> field.
</note>



## S3 Storage


```yaml
- name: files
  kind: cloudstorage.s3
  bucket: "my-bucket"
  config: app.infra:aws_config
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `bucket` | string | Conditional | S3 bucket name. Supply via `${env:NAME}` when it differs per deployment |
| `config` | reference | Yes | AWS config entry reference |
| `endpoint` | string | No | Custom endpoint for S3-compatible services (inline or `${env:NAME}`) |



### S3-Compatible Services


For MinIO or other S3-compatible services, set a custom endpoint:

```yaml
- name: local_storage
  kind: cloudstorage.s3
  bucket: "local-bucket"
  config: app.infra:aws_config
  endpoint: "http://localhost:9000"
```

When an endpoint is provided, path-style access is enabled automatically.



## Multipart Uploads


Presigned multipart uploads are a provider capability, not a runtime feature. The `cloudstorage.s3` kind implements them; a provider that does not support the multipart protocol fails `create_multipart_upload`, `presigned_part_urls`, `complete_multipart_upload` and `abort_multipart_upload` with `errors.UNAVAILABLE`.

Parts of an upload that is never completed or aborted stay stored and billed. Applications abort on every failure path, but a crashed client leaves nothing to run that abort. Configure an `AbortIncompleteMultipartUpload` lifecycle rule on the bucket as the backstop:

```json
{
  "Rules": [
    {
      "ID": "abort-incomplete-multipart",
      "Status": "Enabled",
      "Filter": { "Prefix": "" },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
```



## Ranged Reads


`open_reader` reads an object through ranged GETs and pins the object's ETag with `If-Match` on every read. A provider that does not return an ETag on the initial stat fails the call with `errors.UNAVAILABLE`, and a provider that ignores `If-Match` loses the overwrite protection - the read then cannot detect that it mixed two object generations.



## Lua API


See [Cloud Storage Module](lua/storage/cloud.md) for operations (list, upload, download, delete, presigned URLs, multipart uploads, ranged readers).



## See Also


- [Cloud Storage Module](lua/storage/cloud.md) - Lua API reference
- [Filesystem](system/filesystem.md) - Local filesystem entries
- [Queue](system/queue.md) - SQS handler shares the same `config.aws` entries



## Navigation

Previous: "Filesystem" (system/filesystem)
Next: "Environment System" (system/env)
