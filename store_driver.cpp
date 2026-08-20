// Drive the store and measure the claim it exists to test.
//
//   store_driver <avatars> <seconds> [shards]
//
// The claim, from `docs/logbook/store.md`: commits in flight are worth 44 times, and
// more database handles are worth nothing. So this opens many avatars, keeps many commits
// outstanding at once, and prints commits for each second.
//
// What actually creates depth, which is worth being exact about. A commit blocks its thread
// inside `xSync` until FoundationDB answers, so one thread can hold exactly one commit in
// flight. The store runs a thread for each shard, so the number of commits in flight is the
// number of shards, and no arrangement of avatars changes that. Avatars past the shard count
// queue behind the ones being served; they do not add depth.
//
// That is why this sweeps shards rather than avatars alone. Avatar count still has to be at
// least the shard count, or shards sit idle and the measurement is of an empty store, so the
// driver refuses that case rather than reporting a number for it.
//
// SPDX-License-Identifier: Apache-2.0
#include "iox2_api.h"
#include "weft/bus.hpp"
#include "weft/store.hpp"

#include <chrono>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

// One shard's ports, from the caller's side: requests out, replies in.
struct Shard {
    iox2_node_h node = nullptr;
    iox2_port_factory_pub_sub_h requests = nullptr;
    iox2_port_factory_pub_sub_h replies = nullptr;
    iox2_publisher_h publisher = nullptr;
    iox2_subscriber_h subscriber = nullptr;
};

iox2_port_factory_pub_sub_h open_service(iox2_node_h& node, const char* service_name,
                                         const char* type_name, std::size_t size,
                                         std::size_t align) {
    iox2_service_name_h name = nullptr;
    if (iox2_service_name_new(nullptr, service_name, std::strlen(service_name), &name)
        != IOX2_OK) {
        return nullptr;
    }
    auto builder = iox2_service_builder_pub_sub(
        iox2_node_service_builder(&node, nullptr, iox2_cast_service_name_ptr(name)));
    if (iox2_service_builder_pub_sub_set_payload_type_details(
            &builder, iox2_type_variant_e_FIXED_SIZE, type_name, std::strlen(type_name), size,
            align)
        != IOX2_OK) {
        iox2_service_name_drop(name);
        return nullptr;
    }
    iox2_port_factory_pub_sub_h service = nullptr;
    if (iox2_service_builder_pub_sub_open_or_create(builder, nullptr, &service) != IOX2_OK) {
        iox2_service_name_drop(name);
        return nullptr;
    }
    iox2_service_name_drop(name);
    return service;
}

bool open_shard(Shard& shard, std::uint32_t index) {
    char request_name[128];
    char reply_name[128];
    weft::store_service_name(request_name, sizeof request_name, weft::STORE_REQUEST_SERVICE,
                             index);
    weft::store_service_name(reply_name, sizeof reply_name, weft::STORE_REPLY_SERVICE, index);

    if (iox2_node_builder_create(iox2_node_builder_new(nullptr), nullptr,
                                 iox2_service_type_e_IPC, &shard.node)
        != IOX2_OK) {
        return false;
    }
    shard.requests = open_service(shard.node, request_name, weft::STORE_REQUEST_TYPE,
                                  sizeof(weft::StoreRequest), alignof(weft::StoreRequest));
    shard.replies = open_service(shard.node, reply_name, weft::STORE_REPLY_TYPE,
                                 sizeof(weft::StoreReply), alignof(weft::StoreReply));
    if (!shard.requests || !shard.replies) return false;

    if (iox2_port_factory_publisher_builder_create(
            iox2_port_factory_pub_sub_publisher_builder(&shard.requests, nullptr), nullptr,
            &shard.publisher)
        != IOX2_OK) {
        return false;
    }
    return iox2_port_factory_subscriber_builder_create(
               iox2_port_factory_pub_sub_subscriber_builder(&shard.replies, nullptr), nullptr,
               &shard.subscriber)
           == IOX2_OK;
}

bool send(Shard& shard, std::uint64_t request_id, std::uint64_t avatar, std::uint32_t op,
          const char* sql) {
    iox2_sample_mut_h loan = nullptr;
    if (iox2_publisher_loan_slice_uninit(&shard.publisher, nullptr, &loan, 1) != IOX2_OK) {
        return false;
    }
    void* payload = nullptr;
    std::size_t elements = 0;
    iox2_sample_mut_payload_mut(&loan, &payload, &elements);

    auto* out = static_cast<weft::StoreRequest*>(payload);
    out->request_id = request_id;
    out->avatar = avatar;
    out->op = op;
    const std::size_t n = sql ? std::strlen(sql) : 0;
    out->length = static_cast<std::uint32_t>(n);
    if (n) std::memcpy(out->body, sql, n);

    return iox2_sample_mut_send(loan, nullptr) == IOX2_OK;
}

// Take whatever replies are waiting. Returns how many arrived, and counts the ones that
// failed separately, because a refused write and a completed one are different events and a
// throughput number that mixes them is not a throughput number.
int drain(Shard& shard, std::uint64_t* ok, std::uint64_t* failed) {
    int seen = 0;
    for (;;) {
        iox2_sample_h sample = nullptr;
        if (iox2_subscriber_receive(&shard.subscriber, nullptr, &sample) != IOX2_OK) break;
        if (sample == nullptr) break;

        const void* payload = nullptr;
        std::size_t elements = 0;
        iox2_sample_payload(&sample, &payload, &elements);
        const auto* reply = static_cast<const weft::StoreReply*>(payload);
        if (reply->code == 0) {
            ++*ok;
        } else {
            ++*failed;
        }
        iox2_sample_drop(sample);
        ++seen;
    }
    return seen;
}

double now() {
    using clock = std::chrono::steady_clock;
    return std::chrono::duration<double>(clock::now().time_since_epoch()).count();
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: store_driver <avatars> <seconds> [shards]\n");
        return 2;
    }
    const std::uint64_t avatars = std::strtoull(argv[1], nullptr, 10);
    const double seconds = std::atof(argv[2]);
    const std::uint32_t shards = (argc > 3) ? static_cast<std::uint32_t>(std::atoi(argv[3])) : 1;

    if (avatars < shards) {
        std::fprintf(stderr,
                     "store_driver: %" PRIu64 " avatars over %u shards leaves shards idle, so\n"
                     "the number would measure an empty store. Give at least one each.\n",
                     avatars, shards);
        return 2;
    }

    if (!weft::load_bus()) return 1;
    iox2_set_log_level_from_env_or(iox2_log_level_e_ERROR);

    std::vector<Shard> ports(shards);
    for (std::uint32_t i = 0; i < shards; ++i) {
        if (!open_shard(ports[i], i)) {
            std::fprintf(stderr, "store_driver: shard %u did not open\n", i);
            return 1;
        }
    }

    std::uint64_t id = 0;
    std::uint64_t ok = 0;
    std::uint64_t failed = 0;

    // Open every avatar, and give each one a table to write into. The store raises a fence
    // for each on open, so this is also where ownership is taken.
    for (std::uint64_t avatar = 0; avatar < avatars; ++avatar) {
        Shard& shard = ports[weft::store_shard_of(avatar, shards)];
        send(shard, ++id, avatar, weft::STORE_OPEN, nullptr);
        send(shard, ++id, avatar, weft::STORE_COMMIT,
             "CREATE TABLE IF NOT EXISTS profile (k INTEGER PRIMARY KEY, v TEXT)");
    }
    // Let the opens land before timing starts, so the setup is not in the measurement.
    const double settle = now();
    while (now() - settle < 2.0) {
        for (auto& shard : ports) drain(shard, &ok, &failed);
    }
    ok = 0;
    failed = 0;

    const double start = now();
    std::uint64_t sent = 0;
    while (now() - start < seconds) {
        // One commit outstanding for each avatar. A shard serves its own in order, so this
        // keeps every shard thread busy without pretending one thread can hold two commits.
        for (std::uint64_t avatar = 0; avatar < avatars; ++avatar) {
            Shard& shard = ports[weft::store_shard_of(avatar, shards)];
            if (send(shard, ++id, avatar, weft::STORE_COMMIT,
                     "INSERT OR REPLACE INTO profile VALUES (1, 'x')")) {
                ++sent;
            }
            drain(shard, &ok, &failed);
        }
    }
    const double elapsed = now() - start;

    // Drain what is still outstanding, so the count is of commits that finished.
    const double tail = now();
    while (now() - tail < 5.0) {
        int seen = 0;
        for (auto& shard : ports) seen += drain(shard, &ok, &failed);
        if (seen == 0 && ok + failed >= sent) break;
    }

    std::printf("avatars %" PRIu64 "  shards %u  seconds %.1f\n", avatars, shards, elapsed);
    std::printf("commits %" PRIu64 "  failed %" PRIu64 "  commits/second %.0f\n", ok, failed,
                elapsed > 0 ? static_cast<double>(ok) / elapsed : 0.0);
    std::printf("depth is the shard count, not the avatar count: a commit holds its thread\n"
                "inside xSync, so sweep shards to move this number.\n");

    for (auto& shard : ports) {
        iox2_subscriber_drop(shard.subscriber);
        iox2_publisher_drop(shard.publisher);
        iox2_port_factory_pub_sub_drop(shard.replies);
        iox2_port_factory_pub_sub_drop(shard.requests);
        iox2_node_drop(shard.node);
    }
    return failed ? 1 : 0;
}
