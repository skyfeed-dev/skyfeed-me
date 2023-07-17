# SkyFeed Builder Feed Generator

This code is powering `skyfeed.me`. All feeds published using the SkyFeed Builder use `did:web:skyfeed.me`, so all requests for them end up here.

The feed generator fetches the `app.bsky.feed.generator` record for every requested feed from `bsky.social` and then uses https://github.com/skyfeed-dev/query-engine to generate the feed skeleton. It also adds a caching layer (60 seconds) and pagination.

If you want to self-host your SkyFeed Builder feeds, these are the rough steps:
1. Setup an instance of https://github.com/skyfeed-dev/indexer to index the firehose data in SurrealDB
2. Deploy https://github.com/skyfeed-dev/query-engine somewhere
3. In this repo: Copy `.env.example` to `.env` and edit the values
4. Run `dart run bin/skyfeed_me.dart` and setup a reverse proxy for it, for example `feed-generator.example.com`
5. Update your existing published `app.bsky.feed.generator` records to use `did:web:feed-generator.example.com` instead of `did:web:skyfeed.me`

If you prefer you can build static binaries using `dart compile exe bin/skyfeed_me.dart` for the platform you're on.