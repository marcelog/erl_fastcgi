erl_fastcgi
===========

A small and simple [FastCGI](https://web.archive.org/web/20160119141816/http://www.fastcgi.com/drupal/node/6?q=node%2F22#S3.3)
client written in Erlang.

# Build

```bash
make
```

# Installing
In your <a href="http://www.rebar3.org/">Rebar</a> project:

```
{deps, [
  {erl_fastcgi, {git, "git://github.com/marcelog/erl_fastcgi", {ref, "master"}}}
]}.
```

# Use example
```erlang
test() ->
  Host = "127.0.0.1",
  Port = 9000,
  TryToReconnectEveryMillis = 1000,

  {ok, FastCGIConnection} = erl_fastcgi:start_link(
    Host, Port, TryToReconnectEveryMillis
  ),

  ARandomRequestId = 600,
  erl_fastcgi:run(FastCGIConnection, ARandomRequestId, [
    {"SCRIPT_FILENAME", "/tmp/test.php"},
    {"QUERY_STRING", ""},
    {"REQUEST_METHOD", "GET"},
    {"CONTENT_TYPE", "text/html"},
    {"CONTENT_LENGTH", "0"},
    {"SCRIPT_NAME", "test.php"},
    {"GATEWAY_INTERFACE", "CGI/1.1"},
    {"REMOTE_ADDR", "1.1.1.1"},
    {"REMOTE_PORT", "1111"},
    {"SERVER_ADDR", "127.0.0.1"},
    {"SERVER_PORT", "3838"},
    {"SERVER_NAME", "host.com"}
  ], <<>>),

  test_wait(Pid).

test_wait(Pid) ->
  receive
    X ->
      io:format("Got: ~p~n", [X]),
      test_wait(Pid)
  after
    5000 -> close(Pid)
  end.
```

Your process should get messages like these:
```
{fast_cgi_stdout,600,<<"X-Powered-By: PHP/5.6.30\r\nContent-type: text/html; charset=UTF-8\r\n\r\n">>}
{fast_cgi_stdout,600,<<"<html>">>}
{fast_cgi_stdout,600,<<"</html>">>}
{fast_cgi_done,600}
{fastcgi_request_done,600,fast_cgi_connection_reset}
```

# Pooling
There is no pooling support out of the box, but you can use your favorite worker
pool library to run as many of these as needed.

## Related reads
* [Call FastCGI applications from Erlang](http://marcelog.github.io/articles/erlang_fastcgi_client.html)
* [Serve PHP applications with Erlang and Cowboy using FastCGI](http://marcelog.github.io/articles/erlang_cowboy_php_fastcgi.html)

## License
The source code is released under Apache 2 License.

Check [LICENSE](https://github.com/marcelog/erl_fastcgi/blob/master/LICENSE) file for more information.
