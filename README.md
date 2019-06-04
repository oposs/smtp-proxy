# SMTP Authentication Proxy

This non-blocking smtp proxy will use a REST call to determine if the incoming mail is 'OK' or not. In contrast to other implementations, for example the one present in nginx, it will only issue the REST call after receiving the login, and the headers of the email. This allows the external service to not only validate the username and password but also if the sender and recipient addresses are to be permitted.

## Request

```json
{
  "username": "...",
  "password": "...",
  "from": "blah@bar.com",
  "to": ["x@baz.com", "y@baz.com"],
  "headers": [
    { "name": "To", "value": "foo@bar.com"},
     ...
  ]
}
```

## Response

```json
{
  "allow": true,
  "headers": [
    { "name": "To", "value": "foo@bar.com"},
     ...
  ]
}
```

or 

```json
{
  "allow": false,
  "reason": "sorry, not telling"
}
```

## Usage

`smtpproxy.pl` *options*

```
    --man            show man-page and exit
 -h,--help           display this help and exit
    --listen=ip:port on which IP should we listen; use 0.0.0.0 to listen on all
    --user=x         drop privileges and become this user after start
    --tohost=x       host of the SMTP server to proxy to
    --toport=x       port of the SMTP server to proxy to
    --tls_cert=x     file containing a TLS certificate (for STARTTLS)
    --tls_key=x      file containing a TLS key (for STARTTLS)
    --api=x          URL of the authentication API
    --logpath=x      where should the logfile be written to
    --loglevel=x     debug|info|warn|error|fatal
    --smtplog=x      optional detailed log file of SMTP commands and responses
    --credentials    include username and password info in the smtplog
```

Starts an SMTP server on the listen host and port. When a connection is
established, communicates with the client up to the point it has both the
envelope and the mail data headers. It requires STARTTLS be used, and takes
authentication details using the PLAIN mechanism.
It then passes the authentication details, envelope headers, and data headers
to a REST API, which determies if the mail is allowed to be sent and, if so,
what additional headers should be inserted.
Once the mail has been fully received, and if it is allowed to be sent, then
an upstream connection to the target SMTP server is established. The mail is
sent using that SMTP server, with the extra headers inserted. The outcome of
this is then relayed to the client.
