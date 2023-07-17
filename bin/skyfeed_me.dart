import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:alfred/alfred.dart';
import 'package:atproto/atproto.dart';
import 'package:dotenv/dotenv.dart';
import 'package:lib5/lib5.dart';
import 'package:http/http.dart' as http;
import 'package:thirds/blake3.dart';

final feedListStates = <Multihash, List<PostReference>>{};
final feedListStateKeys = <Multihash>[];

final queryCache = <String, List<PostReference>>{};
final queryCacheRefreshes = <String>{};

// final latencyPoints = <Point>[];
final feedConcurrencyLocks = <String, int>{};
final httpClient = http.Client();

late final DotEnv env;

int counter = 0;
int reqCount = 0;
int reqCountPerSec = 0;

void main(List<String> arguments) async {
  env = DotEnv(includePlatformEnvironment: true)..load();

  final app = Alfred();

  app.all('*', cors());

  Stream.periodic(Duration(seconds: 60)).listen((event) {
    print('[cache] feed state count: ${feedListStateKeys.length}');
    while (feedListStateKeys.length > 10000) {
      final key = feedListStateKeys.removeAt(0);
      feedListStates.remove(key);
    }
  });

  Stream.periodic(Duration(seconds: 60)).listen((event) async {
    for (final key in queryCache.keys) {
      queryCacheRefreshes.add(key);
    }
  });

  app.get('/xrpc/app.bsky.feed.getFeedSkeleton', (req, res) async {
    reqCount++;
    reqCountPerSec++;
    var feedUri = req.requestedUri.queryParameters['feed']!;

    final String? cursor = req.requestedUri.queryParameters['cursor'];
    final limit = int.parse(req.requestedUri.queryParameters['limit'] ?? '50');

    if (cursor != null) {
      final parts = cursor.split('+');
      final feedStateId = Multihash.fromBase64Url(parts[0]);

      if (feedListStates.containsKey(feedStateId)) {
        print('[feed] cached $feedUri cursor: $parts');
        final list = feedListStates[feedStateId]!;
        int start = 0;

        final idCursor = parts.last;

        for (final post in list) {
          if (post.cursor == idCursor) {
            start++;
            break;
          }
          start++;
        }

        final feedList = list.sublist(start, min(start + limit, list.length));

        if (feedList.length < limit) {
          return {
            'feed': feedList.map((e) => e.map).toList(),
          };
        } else {
          return {
            'cursor': '${feedStateId.toBase64Url()}+${feedList.last.cursor}',
            'feed': feedList.map((e) => e.map).toList(),
          };
        }
      }
    }

    // TODO Support personalized feeds
    String? did;
    try {
      final token = req.headers.value('authorization')!.substring(7);
      final data =
          json.decode(utf8.decode(base64Url.decode(token.split('.')[1])));
      // TODO did = didToKey(data['iss']);
    } catch (_) {}

    // }
    if (!queryCache.containsKey(feedUri)) {
      print('[debug] fetch type 1');
      final res = await fetchQuery(feedUri, false);
      if (res is Map) {
        return res;
      }
    } else if (queryCacheRefreshes.contains(feedUri)) {
      queryCacheRefreshes.remove(feedUri);
      // TODO More efficient

      final ts = feedConcurrencyLocks[feedUri] ?? 0;
      if (ts <
          (DateTime.now()
              .subtract(Duration(minutes: 3))
              .millisecondsSinceEpoch)) {
        print('[debug] fetch type 2');
        await fetchQuery(feedUri, true);
      } else {
        print('[debug] fetch type 3');
        fetchQuery(feedUri, true);
      }
    }

    final list = queryCache[feedUri] ?? [];

    int start = 0;

    if (cursor != null) {
      final idCursor = cursor.split('+').last;

      for (final post in list) {
        if (post.cursor == idCursor) {
          start++;
          break;
        }
        start++;
      }
    }

    final feedStateId = Multihash(Uint8List.fromList(
        blake3(utf8.encode(list.map((e) => e.cursor).toString()))));

    feedListStates[feedStateId] = list;
    feedListStateKeys.add(feedStateId);

    final feedList = list.sublist(start, min(start + limit, list.length));

    if (feedList.length < limit) {
      return {
        'feed': feedList.map((e) => e.map).toList(),
      };
    } else {
      return {
        'cursor': '${feedStateId.toBase64Url()}+${feedList.last.cursor}',
        'feed': feedList.map((e) => e.map).toList(),
      };
    }
  });

  app.get('/health', (req, res) => '');

  app.get(
    '/.well-known/did.json',
    (req, res) {
      res.headers.set('cache-control', 'max-age=600');
      return {
        "@context": ["https://www.w3.org/ns/did/v1"],
        "id": "did:web:${env['FEEDGEN_HOSTNAME']}",
        "service": [
          {
            "id": "#bsky_fg",
            "type": "BskyFeedGenerator",
            "serviceEndpoint": "https://${env['FEEDGEN_HOSTNAME']}"
          }
        ]
      };
    },
  );

  app.get('/', (req, res) {
    return 'Hi, I\'m the Feed Generator for the SkyFeed Builder!';
  });

/*   Stream.periodic(Duration(seconds: 1)).listen((event) async {
    try {
      final points = <Point>[];
      final dt = DateTime.now().toUtc();

      final point = Point('skyfeed_me_requests')
          .addField('reqs_per_sec', reqCountPerSec)
          .time(dt);
      reqCountPerSec = 0;

      points.add(point);

      final writeService = influxClient.getWriteService();
      await writeService.write(points);
      final lcopy = List.of(latencyPoints);
      latencyPoints.clear();
      if (lcopy.isNotEmpty) {
        await writeService.write(lcopy);
      }
    } catch (e, st) {
      print(e);
      print(st);
    }
  }); */

  await app.listen();
  while (true) {
    await Future.delayed(Duration(seconds: 10));
    if (reqCount < 1) {
      exit(1);
    }

    reqCount = 0;
  }
}

Future<dynamic> fetchQuery(String feedUri, bool force) async {
  if (!force && feedConcurrencyLocks.containsKey(feedUri)) {
    final ts = feedConcurrencyLocks[feedUri]!;
    while (!queryCache.containsKey(feedUri) &&
        ts >
            (DateTime.now()
                .subtract(Duration(seconds: 10))
                .millisecondsSinceEpoch)) {
      await Future.delayed(Duration(milliseconds: 50));
    }
  }

  if (force || !queryCache.containsKey(feedUri)) {
    feedConcurrencyLocks[feedUri] = DateTime.now().millisecondsSinceEpoch;
    print('[feed] fetching $feedUri');

    try {
      final atUri = AtUri.parse(feedUri);
      final feedgenRecordRes = await httpClient.get(
        Uri.https('bsky.social', '/xrpc/com.atproto.repo.getRecord', {
          'repo': atUri.hostname,
          'collection': atUri.collection,
          'rkey': atUri.rkey,
        }),
      );
      if (feedgenRecordRes.statusCode != 200) {
        throw 'HTTP ${feedgenRecordRes.statusCode}';
      }
      final feedgenRecord = jsonDecode(feedgenRecordRes.body);

      final config = feedgenRecord['value']['skyfeedBuilder'];

      print('[query-engine] ${config['displayName']} ($atUri)');
      final start = DateTime.now();

      final res = await httpClient.post(
        Uri.parse(env['QUERY_ENGINE_URL']!),
        body: jsonEncode(config),
        headers: {
          'content-type': 'application/json',
        },
      );
      if (res.statusCode != 200) {
        throw 'HTTP ${res.statusCode}: ${res.body}';
      }
      final dt = DateTime.now();
      final millis = dt.difference(start).inMilliseconds;
      /* final point = Point('skyfeed_me_latency')
          .addTag('rkey', atUri.rkey)
          .addField('t', millis)
          .time(dt);
      latencyPoints.add(point); */

      if (millis > 1000) {
        print('SLOW QUERY ${millis}ms ${jsonEncode(config)}');
      }

      final List posts = jsonDecode(res.body)['feed'];

      queryCache[feedUri] = posts
          .map<PostReference>(
            (m) => PostReference(m, m['post']),
          )
          .toList();

      /*    if (e.containsKey('repost')) {
            final map = {
              'reason': {
                '\$type': 'app.bsky.feed.defs#skeletonReasonRepost',
                'repost': convertRepostIdToUri(e['repost']),
              },
              'post': convertPostIdToUri(e['id']),
            };
            // print('repost map $map');
            return PostReference(
              map,
              e['id'],
            );
          } else {
            try {
              return PostReference(
                {'post': convertPostIdToUri(e['id'])},
                e['id'],
              );
            } catch (e, st) {
              return PostReference({}, '');
            }
          } */
    } catch (e, st) {
      print('$e $st');
      return {
        'feed': [
          {
            'post':
                'at://did:plc:tenurhgjptubkk5zf5qhi3og/app.bsky.feed.post/3jznn23kxpr2o'
          }
        ]
      };
    }
  }
}

class PostReference {
  final Map<String, dynamic> map;
  final String cursor;
  PostReference(this.map, this.cursor);
}
