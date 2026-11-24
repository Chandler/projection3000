#pragma once
#include <boost/asio/steady_timer.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <chrono>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

// A total deadline includes DNS, connect, headers, and body, even if a peer
// accepts a connection and never responds. Called only by module workers.
inline std::vector<std::uint8_t> fetch_module(
    const std::string &host, const std::string &port,
    const std::string &authority, const std::string &target,
    std::chrono::milliseconds timeout = std::chrono::seconds(3)) {
    namespace asio = boost::asio;
    namespace beast = boost::beast;
    namespace http = beast::http;
    asio::io_context io;
    asio::ip::tcp::resolver resolver(io);
    beast::tcp_stream stream(io);
    asio::steady_timer deadline(io, timeout);
    http::request<http::empty_body> request{http::verb::get, target, 11};
    request.set(http::field::host, authority);
    request.set(http::field::user_agent, "vibe-native-render");
    http::response_parser<http::vector_body<std::uint8_t>> response;
    response.body_limit(2 * 1024 * 1024);
    beast::flat_buffer buffer;
    beast::error_code failure;
    bool finished = false;
    auto finish = [&](beast::error_code error) {
        if (finished) return;
        finished = true;
        failure = error;
        deadline.cancel();
        resolver.cancel();
        beast::error_code ignored;
        stream.socket().close(ignored);
    };
    deadline.async_wait([&](beast::error_code error) {
        if (!error) finish(asio::error::timed_out);
    });
    resolver.async_resolve(host, port, [&](beast::error_code error, auto endpoints) {
        if (finished) return;
        if (error) { finish(error); return; }
        stream.async_connect(endpoints, [&](beast::error_code error, auto) {
            if (finished) return;
            if (error) { finish(error); return; }
            http::async_write(stream, request, [&](beast::error_code error, auto) {
                if (finished) return;
                if (error) { finish(error); return; }
                http::async_read(stream, buffer, response, [&](beast::error_code error, auto) {
                    finish(error);
                });
            });
        });
    });
    io.run();
    if (failure) throw std::runtime_error("Vector module unavailable: " + failure.message());
    if (response.get().result() != http::status::ok)
        throw std::runtime_error("Vector module HTTP " + std::to_string(response.get().result_int()));
    return std::move(response.get().body());
}
