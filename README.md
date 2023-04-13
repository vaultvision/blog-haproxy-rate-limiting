# HAProxy Rate Limiting

This repo contains a set of patterns for HAProxy rate limiting and general configuration in use at [Vault Vision](github.com/vaultvision/). We will do our best to share what we learned in our search for a fair balance between flexibility and complexity.

The official [HAProxy Blog] has a lot of great resources on configuring HAProxy. This repo will combine the concepts expalined in [HAProxy Rate Limiting: Four Examples], [Introduction to HAProxy Maps], [The Four Essential Sections of an HAProxy Configuration] and several other resources into a full example configuration that can be ran locally.


## Basic Goals

- Rate limiting of connections globally by src address
- Rate limiting of http requests by src address + URL
- Simple mechanism to severly limit or block malicious users entirely by src address
- Minimize resources consumed by ongoing malicious users automatically
- Make use of [HAProxy Maps] for configuration values to enable easy runtime changes without reloads.


## Quick Start

To start running the example in a docker container:
```bash
make
```

> *note*  Without make you can use:
> ```bash
> docker-compose up -d
> ```

When you're finished you can bring it down and remove any volumes with:
```bash
make clean
```

> *note*  Without make you can use:
> ```bash
> docker-compose down -v
> ```

Once running you will be able to access the following endpoints:

 - *default backend* [http://localhost:8900/](http://localhost:8900/)
 - *stats backend* [http://localhost:8901/stats](http://localhost:8901/stats)
 - *metrics backend* [http://localhost:8901/metrics](http://localhost:8901/metrics)

> *note*  You may need to replace localhost with your containers address depending on your docker configuration.

In addition a special debug page will be rendered at the following urls:

 - *debug page* http://localhost:8900/haproxy

These special pages display the debug page but also override the current pages rate limit with the numeric value in the path:

 - http://localhost:8900/haproxy/rates/1
 - ... 
 [2](http://localhost:8900/haproxy/rates/2)
 [4](http://localhost:8900/haproxy/rates/4)
 [8](http://localhost:8900/haproxy/rates/8)
 [16](http://localhost:8900/haproxy/rates/16)
 [32](http://localhost:8900/haproxy/rates/32)
 [64](http://localhost:8900/haproxy/rates/64)
 ...
 - http://localhost:8900/haproxy/rates/128


There is also a `/v1` prefixed path that will load the API default rates which serves JSON when the limits are exceeded:

 - http://localhost:8900/v1/haproxy/rates/1
 - ... 
 [2](http://localhost:8900/v1/haproxy/rates/2)
 [4](http://localhost:8900/v1/haproxy/rates/4)
 [8](http://localhost:8900/v1/haproxy/rates/8)
 [16](http://localhost:8900/v1/haproxy/rates/16)
 [32](http://localhost:8900/v1/haproxy/rates/32)
 [64](http://localhost:8900/v1/haproxy/rates/64)
 ...
 - http://localhost:8900/v1/haproxy/rates/128

Feel free to hit any of them and start spamming F5 to see things in action.

We can use the [Makefile](https://github.com/vaultvision/blog-haproxy-rate-limiting/blob/main/Dockerfile) to do some other simple operations. To show the currently loaded maps:
```bash
make show-maps
```

> *note*  Without make you can use:
> ```bash
> echo "echo 'show map' | socat /tmp/api.sock -;" \
>         "echo 'show map /usr/local/etc/haproxy/maps/config.map' | socat /tmp/api.sock -;" \
>         "echo 'show map /usr/local/etc/haproxy/maps/rates-by-url.map' | socat /tmp/api.sock -;" \
>                 | docker exec -i haproxy bash -c "$(cat -)"
> ```

To show the current state of the stick-tables:
```bash
make show-tables
```

> *note*  Without make you can use:
> ```bash
> echo "echo 'show table st_global' | socat /tmp/api.sock -;" \
>	"echo 'show table st_paths' | socat /tmp/api.sock -;" \
>		| docker exec -i haproxy bash -c "while true; do $(cat -) sleep 1; done"
> ```


## Configuration Breakdown

Here is a break down of [haproxy.cfg](https://github.com/vaultvision/blog-haproxy-rate-limiting/blob/main/config/haproxy.cfg).


### global

The [global section](https://docs.haproxy.org/2.7/configuration.html#3) of our config:
```
global
    log stdout local0 debug

    stats socket /tmp/api.sock user haproxy group haproxy mode 600 level admin expose-fd listeners
    stats timeout 30s

    maxconn 1024

    # st_global limits
    set-var proc.vv_global_conn_cur_limit str("vv_global_conn_cur_limit"),map_str(/usr/local/etc/haproxy/maps/config.map,30)
    set-var proc.vv_global_conn_rate_limit str("vv_global_conn_rate_limit"),map_str(/usr/local/etc/haproxy/maps/config.map,31)
    set-var proc.vv_global_http_rate_limit str("vv_global_http_rate_limit"),map_str(/usr/local/etc/haproxy/maps/config.map,32)

    # st_path limits
    set-var proc.vv_path_default_http_rate_limit str("vv_path_default_http_rate_limit"),map_str(/usr/local/etc/haproxy/maps/config.map,33)
    set-var proc.vv_path_static_http_rate_limit str("vv_path_static_http_rate_limit"),map_str(/usr/local/etc/haproxy/maps/config.map,34)
    set-var proc.vv_path_api_http_rate_limit str("vv_path_api_http_rate_limit"),map_str(/usr/local/etc/haproxy/maps/config.map,35)
```

We start by enabling the [stats](https://docs.haproxy.org/2.7/configuration.html#stats) socket. This will allow us to query our stick tables and make changes to our maps at runtime. It's important to make sure to never expose this to the public, securing this is out of scope for this article:

```
    stats socket /tmp/api.sock user haproxy group haproxy mode 600 level admin expose-fd listeners
    stats timeout 30s
```

> *note* that in our docker container it was simpler to use `/tmp`, but an appropriately permissioned location within `/var/run` would be better in most distributions.

The next section is one of the more important baseline settings for haproxy as noted in many resources around the web. In production tweak this to what the upper bounds of your systems capabilities are. Find guidance on setting this value as well as the frontend and backend sections in the HAProxy Blog article [Protect Servers with HAProxy Connection Limits and Queues].

```
    maxconn 1024
```

> *note*  An interesting quirk to this as of HAProxy 2.7 is that if you don't set maxconn if you don't set maxconn it will be set to whatever the number for ulimit -n is. While it can be 1024, on some systems it may be higher or lower. For my workstation it was actually 1_073_741_816 which equates to an immediate 164G of virtual memory usage and 200% CPU usage before finally ooming.

For general configuration we have some values loaded from a map. The location of this file depends on how HAProxy is installed on your system. It will generally be rooted within the `etc` directory under the name `haproxy`, for example:

- Docker image *haproxy:2.7* uses `/usr/local/etc/haproxy`
- Arch, Debian and other Linux distros use `/etc/haproxy`


We choose to make use of [set-var](https://docs.haproxy.org/2.7/configuration.html#set-var) and [map_str](https://docs.haproxy.org/2.7/configuration.html#7.3.1-map) to assign the values once when the process tarts in the global section of the configuration.


```
    # st_global limits
    set-var proc.vv_global_conn_cur_limit str("vv_global_conn_cur_limit"),map_str(/usr/local/etc/haproxy/maps/config.map,30)
    set-var proc.vv_global_conn_rate_limit str("vv_global_conn_rate_limit"),map_str(/usr/local/etc/haproxy/maps/config.map,31)
    set-var proc.vv_global_http_rate_limit str("vv_global_http_rate_limit"),map_str(/usr/local/etc/haproxy/maps/config.map,32)

    # st_path limits
    set-var proc.vv_path_default_http_rate_limit str("vv_path_default_http_rate_limit"),map_str(/usr/local/etc/haproxy/maps/config.map,33)
    set-var proc.vv_path_static_http_rate_limit str("vv_path_static_http_rate_limit"),map_str(/usr/local/etc/haproxy/maps/config.map,34)
    set-var proc.vv_path_api_http_rate_limit str("vv_path_api_http_rate_limit"),map_str(/usr/local/etc/haproxy/maps/config.map,35)
```

> *note*  We chose to use `proc.<var-name>` once at startup because we didn't need the ability to change these config values at runtime. You could just as easily move them into the frontend, or backend seconds as `txn.<var-name>` variables to load them each request.


> *note* The trailing argument to `map_str` is the default value. We set it to a sequence of numbers 30 through 35 just as the config values are set to 20 through 25. This makes it easy to identify when the key is missing from the `config.map` since the value will change from 20 to 30.


Below is the [config.map](https://github.com/vaultvision/blog-haproxy-rate-limiting/blob/main/config/maps/config.map) file for our example:
```bash
# Config Key | Config Value
##

# Global - maximum concurrent connections
vv_global_conn_cur_limit 20

# Global (by src, per 10s) - maximum connection rate
vv_global_conn_rate_limit 21

# Global (by src, per 10s) - maximum http requests to all resources.
vv_global_http_rate_limit 22

# Global (by base32+src, per 10s) - maximum http requests to all other resources
vv_path_default_http_rate_limit 23

# Global (by base32+src, per 10s) - maximum http requests to static resources
vv_path_static_http_rate_limit 24

# Global (by base32+src, per 10s) - maximum http requests to API
vv_path_api_http_rate_limit 25
```

Each one has a comment explaining what it controls, we will touch on them more as we dive deeper into our configuration.

> *note* The values are just low sequential numbers 20-25 so it's easy to identify. In production you will want to set these to something that makes sense for your services.


### defaults

Many configuration directives in the manual will specify that when they will check the "defaults section" when they are not declared. Our defaults section is:
```
defaults
    log    global

    mode   http
    option httplog
    option dontlognull

    timeout connect 5000
    timeout client  50000
    timeout server  50000

    errorfile 429 /usr/local/etc/haproxy/errors/vv-error-html-429.http
```

First we setup the default logging and some basic http options. It's important to set timeouts that make sense for your use, but these are sane defaults for most web services if you aren't sure.


It's worth calling out the [errorfile](https://docs.haproxy.org/2.7/configuration.html#4-errorfile) directive, this is the page that is displayed when an error occurs within haproxy. We created error pages for every possible status code returned by haproxy as defined in the manual, but omitted them to the one we used most for this example to show a simple method for conditionally displaying JSON / HTML errors.

> *note*  From the documentation: "It is important to understand that this keyword is not meant to rewrite errors returned by the server, but errors detected and returned by HAProxy. This is why the list of supported errors is limited to a small set."


### frontend fe_metrics

This won't be compiled in by default in every distribution and should never be exposed publicly, we include it because it's a great place to see some metrics on HAProxy internals in a format many people are familiar with. The only interesting part here would be the use of an [Environment Variable](https://docs.haproxy.org/2.7/configuration.html#2.3) with a default value declared for the bind address.

This section is defined as:
```
frontend fe_metrics
    bind "${VV_HAPROXY_FE_METRICS_LISTEN_ADDR-:8901}"
    http-request use-service prometheus-exporter if { path /metrics }
    stats enable
    stats uri /stats
    stats refresh 10s
```


### http-errors

We declare two error groups with the [http-errors](https://docs.haproxy.org/2.7/configuration.html#3.8-http-errors) directive. We will use html or json errors depending on the call thats being rate limited. You can define many other status codes, for this example we have:
```
http-errors http_errors_html
    errorfile 429 /usr/local/etc/haproxy/errors/vv-error-html-429.http


http-errors http_errors_json
    errorfile 429 /usr/local/etc/haproxy/errors/vv-error-json-429.http
```

Using it is simple, just use the [errorfiles](https://docs.haproxy.org/2.7/configuration.html#4.2-errorfiles) directive in any valid section like this:

```
backend be_tarpit_json
    errorfiles http_errors_json
```


### backend be_debug

We declare a special debug backend that utilizes the [log formatted](https://docs.haproxy.org/2.7/configuration.html#8.2.4) string support in the [http-request return](https://docs.haproxy.org/2.7/configuration.html#4.2-http-request%20return) declaration:
```
# Debug
backend be_debug
    http-request return status 200 content-type text/html lf-file /usr/local/etc/haproxy/debug.html
```

The lg formatted file it serves is [debug.html](https://github.com/vaultvision/blog-haproxy-rate-limiting/blob/main/config/debug.html), which is a regular html file mixed with some special variables like so:

```html
        <div>
            <h2>Env</h2>
            <p>Config values from: <code>/etc/sysconfig/vv/machine.env</code></p>
            <table>
                <tbody>
                    <tr>
                        <th>VV_HAPROXY_DEBUG</th>
                        <td>%[env(VV_HAPROXY_DEBUG)]</td>
                    </tr>
                    ...
                    <tr>
                        <th>VV_HAPROXY_FE_METRICS_LISTEN_ADDR</th>
                        <td>%[env(VV_HAPROXY_FE_METRICS_LISTEN_ADDR)]</td>
                    </tr>
                </tbody>
            </table>
        </div>

        <div>
            <h2>Txn</h2>
            <table>
                <tbody>
                    <tr>
                        <th>txn.vv_global_conn_cur_current</th>
                        <td>%[var(txn.vv_global_conn_cur_current)]</td>
                    </tr>
                    ...
                    <tr>
                        <th>txn.vv_path_http_rate_limit</th>
                        <td>%[var(txn.vv_path_http_rate_limit)]</td>
                    </tr>
                </tbody>
            </table>
        </div>

        <div>
            <h2>Acls</h2>
            <table>
                <tbody>
                    <tr>
                        <th>is_global_conn_cur_limited</th>
                        <td>%[var(txn.vv_acl_str_is_global_conn_cur_limited)]</td>
                    </tr>
                    ....
                    <tr>
                        <th>is_path_http_rate_limited</th>
                        <td>%[var(txn.vv_acl_str_is_path_http_rate_limited)]</td>
                    </tr>
                </tbody>
            </table>
        </div>
```

Which is a really useful method to debug your HAProxy configuration without inline logging or capturing. You can simply intercept a route normally headed to a different backend and print the debug page instead.


### backend st_table-name

You are limited to one stick table per frontend or backend. A way to work around that limitation is to declare your stick table in a backend instead. You can then access it using the special converter functions with `table_` prefixes such as [table_http_req_rate](https://docs.haproxy.org/2.7/configuration.html#7.3.1-table_http_req_rate). The two [stick tables](https://docs.haproxy.org/2.7/configuration.html#4.2-stick-table%20type) we use are found below:
```
# Stick Table - ipv6 - rate limiting by src ip
backend st_global

    # For local testing I have this set to 1k, tweak to 100k-1m for prod
    # depending on your systems memory.
    stick-table  type ipv6  size 1k  expire 10s  store gpc0,conn_cur,conn_rate(10s),http_req_rate(10s)


# Stick Table - binary - rate limiting by (src + host + path)
backend st_paths

    # This has much more entries in it, so setting it to be st_global * N
    # is a good idea, where N is something factoring the total src+host+path
    # combinations you want to track.
    stick-table  type binary  len 32  size 10k  expire 10s  store gpc0,conn_rate(10s),http_req_rate(10s)
```


### backend be_tarpit_content-type

We also declare two [tarpits](https://docs.haproxy.org/2.7/configuration.html#4.2-http-request%20tarpit) which we send users to when they exceed path based request rate limits. It's not until they exceed connection rate limits that we begin to block new connections all together. One uses our html errorfiles and the other json:
```
# Tarpit - ui
backend be_tarpit_html
    errorfiles http_errors_html
    timeout tarpit 2s
    http-request tarpit deny_status 429


# Tarpit - api
backend be_tarpit_json
    errorfiles http_errors_json
    timeout tarpit 2s
    http-request tarpit deny_status 429
```


### backend be_examples

We declare several similar backends that we can use for testing which simply return the name of the backend using lf-string:
```
backend be_example_ui
    mode http
    errorfiles http_errors_html
    http-request return status 200 content-type text/plain lf-string "backend: be_example_ui"

backend be_example_api
    mode http
    errorfiles http_errors_json
    http-request return status 200 content-type text/plain lf-string "backend: be_example_api"
```


### frontend fe_http

This is the primary frontend which has the lions share of complexity. Given it's size we can follow the inline comments located in the [haproxy.cfg](https://github.com/vaultvision/blog-haproxy-rate-limiting/blob/main/config/haproxy.cfg) config file directly.


## Who are we?

[Vault Vision](https://vaultvision.com) is built on open source technologies and is committed to building a welcoming community developers can trust.

Visit [https://docs.vaultvision.com](https://docs.vaultvision.com) to learn more!


----

Vault Vision projects adopt the [Contributor Covenant Code of Conduct](https://github.com/vaultvision/.github/blob/main/CODE_OF_CONDUCT.md) and practice responsible disclosure as outlined in our [Security Policy](https://github.com/vaultvision/.github/blob/main/SECURITY.md).




[HAProxy Blog]: https://www.haproxy.com/blog/
[Vault Vision]: https://vaultvision.com/
[Vault Vision Github]: https://github.com/vaultvision/
[HAProxy Maps]: https://www.haproxy.com/blog/introduction-to-haproxy-maps/

[Rate Limiting]: https://www.haproxy.com/blog/four-examples-of-haproxy-rate-limiting/

[The Four Essential Sections of an HAProxy Configuration]: https://www.haproxy.com/blog/the-four-essential-sections-of-an-haproxy-configuration/
[Introduction to HAProxy Maps]: https://www.haproxy.com/blog/introduction-to-haproxy-maps/
[HAProxy Rate Limiting: Four Examples]: https://www.haproxy.com/blog/four-examples-of-haproxy-rate-limiting/
[Protect Servers with HAProxy Connection Limits and Queues]: https://www.haproxy.com/blog/protect-servers-with-haproxy-connection-limits-and-queues/

