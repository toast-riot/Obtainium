import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart'; // TODO: rm
import 'package:easy_localization/easy_localization.dart';
import 'package:html/dom.dart' as dom;
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:html/parser.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:flutter/material.dart';

/// AppSource implementation for itch.io.
///
/// Itch.io uses a multi-step dynamic download flow that often requires
/// bypassing "Name your price" lightboxes and resolving tokenized download
/// pages to find direct asset links.
class ItchIO extends AppSource {
  ItchIO() {
    hosts = ['itch.io'];
    name = 'itch.io';
    allowSubDomains = true;
    sourceConfigSettingFormItems = [
      GeneratedFormTextField(
        'itchio-creds',
        label: tr('itchioAPIKeyLabel'),
        password: true,
        required: false,
        belowWidgets: [
          const SizedBox(height: 4),
          InkWell(
            onTap: () {
              launchUrlString(
                'https://itch.io/user/settings/api-keys',
                mode: LaunchMode.externalApplication,
              );
            },
            child: Text(
              tr('about'),
              style: const TextStyle(
                decoration: TextDecoration.underline,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    ];
  }

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    RegExp standardUrlRegEx = RegExp(
      '^https?://[a-z0-9-]+.${getSourceRegex(hosts)}/[^/]+',
      caseSensitive: false,
    );
    RegExpMatch? match = standardUrlRegEx.firstMatch(url);
    if (match == null) {
      throw InvalidURLError(name);
    }
    return match.group(0)!;
  }

  @override
  Future<Map<String, String>?> getRequestHeaders(
    Map<String, dynamic> additionalSettings,
    String url, {
    bool forAPKDownload = false,
  }) async {
    var headers = <String, String>{};
    if (additionalSettings['extraHeaders'] != null) {
      headers.addAll(
        Map<String, String>.from(additionalSettings['extraHeaders']),
      );
    }
    final apiKey = await _getApiKeyIfAny(additionalSettings);
    if (apiKey != null && url.startsWith('https://api.itch.io/')) {
      headers[HttpHeaders.authorizationHeader] = apiKey;
    }
    return headers.isNotEmpty ? headers : null;
  }

  Future<String?> _getApiKeyIfAny(Map<String, dynamic> additionalSettings) async {
    SettingsProvider settingsProvider = SettingsProvider();
    await settingsProvider.initializeSettings();
    var sourceConfig = await getSourceConfigValues(
      additionalSettings,
      settingsProvider,
    );
    String? apiKey = sourceConfig['itchio-creds'];
    return apiKey != null && apiKey.isNotEmpty ? apiKey : null;
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    final apiKey = await _getApiKeyIfAny(additionalSettings);
    if (apiKey != null) {
      final apiDetails = await _ItchIoApiClient.tryGetLatestAPKDetails(
        source: this,
        standardUrl: standardUrl,
        apiKey: apiKey,
        additionalSettings: additionalSettings,
      );
      if (apiDetails != null) {
        return apiDetails;
      }
    }

    return await _ItchIoWebScraper.tryGetLatestAPKDetails(
      this,
      standardUrl,
      additionalSettings,
    );
  }

  /// Custom itch.io URL fetcher.
  ///
  /// Since the filehost is on Cloudflare R2, we need to resolve the asset URL
  /// after we identified the download.
  @override
  Future<String> assetUrlPrefetchModifier(
    String assetUrl,
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    final apiKey = await _getApiKeyIfAny(additionalSettings);
    if (apiKey != null) {
      final apiUrl = await _ItchIoApiClient.tryResolveAssetUrl(
        source: this,
        assetUrl: assetUrl,
        standardUrl: standardUrl,
        apiKey: apiKey,
        additionalSettings: additionalSettings,
      );
      if (apiUrl != null) {
        return apiUrl;
      }
    }

    final cloudFlareUrl = await _ItchIoWebScraper.tryResolveAssetUrl(
      this,
      assetUrl,
      standardUrl,
      additionalSettings,
    );
    if (cloudFlareUrl != null) {
      return cloudFlareUrl;
    }

    return assetUrl;
  }
}


class _Common {
}

class _ItchIoApiClient {
  static void _log(String message) { // TODO: rm
    if (kDebugMode) {
      // ignore: avoid_print
      print('itchio-api: $message');
    }
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  static List<Map<String, dynamic>> _asUploads(dynamic value) {
    if (value is Map<String, dynamic> && value['uploads'] is List) {
      return (value['uploads'] as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (value is List) {
      return value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return [];
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    try {
      return DateTime.parse(value.toString());
    } catch (_) {
      return null;
    }
  }

  static String? _firstString(Map<String, dynamic>? map, List<String> keys) {
    if (map == null) return null;
    for (var key in keys) {
      var value = map[key];
      if (value != null) {
        var text = value.toString();
        if (text.isNotEmpty) {
          return text;
        }
      }
    }
    return null;
  }

  // TODO: can obtainium handle .zip and .xapk?
  static bool _isAndroidUpload(Map<String, dynamic> upload) {
    final filename = _firstString(upload, ['filename'])?.toLowerCase() ?? '';
    if (!(filename.endsWith('.apk') || filename.endsWith('.xapk') || filename.endsWith('.zip'))) {
      return false;
    }
    final traits = upload['traits'];
    if (traits is List && traits.any((e) => e?.toString() == 'p_android')) {
      return true;
    }
    return false;
  }

  static String? _extractGameIdFromDataJson(dynamic dataJson) {
    final data = _asMap(dataJson);
    return data?['id']?.toString();
  }

  // TODO: test fallback
  static String? _gameTitleFromDataJson(dynamic dataJson, String standardUrl) {
    final data = _asMap(dataJson);
    return _firstString(data, ['title']) ??
        Uri.parse(standardUrl).pathSegments.last;
  }

  // TODO: test fallback
  static String? _gameAuthorFromDataJson(dynamic dataJson, String standardUrl) {
    final data = _asMap(dataJson);
    final authors = data?['authors'];
    if (authors is List && authors.isNotEmpty) {
      final firstAuthor = _asMap(authors.first);
      final name = _firstString(firstAuthor, ['name']);
      if (name != null) {
        return name;
      }
    }
    final links = _asMap(data?['links']);
    final selfUrl = _firstString(links, ['self']);
    if (selfUrl != null) {
      return Uri.parse(selfUrl).host.split('.').first;
    }
    return Uri.parse(standardUrl).host.split('.').first;
  }

  static String _downloadEndpoint(String apiKey, String uploadId) =>
      'https://itch.io/api/1/$apiKey/upload/$uploadId/download';

  static String? _labelForUpload(Map<String, dynamic> upload) {
    return _firstString(upload, ['display_name', 'filename']) ??
        (upload['id'] != null ? 'upload-${upload['id']}' : null);
  }


  // TODO: build is not always present, and filename is not always a good version indicator
  // fallbacks that might work: 'md5_hash', 'updated_at', 'id' (which is incremental and therefore unique but global and not per-game)
  static String? _versionForUpload(Map<String, dynamic> upload) {
    final build = _asMap(upload['build']);
    return _firstString(build, ['user_version']) ??
        _firstString(upload, ['filename']);
  }

  static Future<APKDetails?> tryGetLatestAPKDetails({
    required AppSource source,
    required String standardUrl,
    required String apiKey,
    required Map<String, dynamic> additionalSettings,
  }) async {
    if (apiKey.isEmpty) {
      _log('skip latest-details: [ERROR] missing api key for $standardUrl');
      return null;
    }

    _log('latest-details: start standardUrl=$standardUrl');
    final dataRes = await source.sourceRequest(
      '$standardUrl/data.json',
      additionalSettings,
    );
    if (dataRes.statusCode != 200) {
      _log('latest-details: [ERROR] data.json request failed; falling back to scraper');
      return null;
    }

    final dataJson = jsonDecode(dataRes.body);
    final gameId = _extractGameIdFromDataJson(dataJson);
    if (gameId == null) {
      _log('latest-details: [ERROR] data.json missing game id; falling back to scraper');
      return null;
    }

    final uploadsRes = await source.sourceRequest(
      'https://api.itch.io/games/$gameId/uploads',
      additionalSettings,
    );
    if (uploadsRes.statusCode != 200) {
      _log('latest-details: [ERROR] uploads request failed; falling back to scraper');
      return null;
    }

    final uploadsJson = jsonDecode(uploadsRes.body);
    final uploads = _asUploads(uploadsJson)
        .where(_isAndroidUpload)
        .toList();
    if (uploads.isEmpty) {
      _log('latest-details: [ERROR] no android uploads found; falling back to scraper');
      return null;
    }

    uploads.sort((a, b) {
      final ad = _parseDate(a['updated_at']) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bd = _parseDate(b['updated_at']) ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bd.compareTo(ad);
    });

    final gameTitle = _gameTitleFromDataJson(dataJson, standardUrl) ??
        Uri.parse(standardUrl).pathSegments.last;
    final gameAuthor = _gameAuthorFromDataJson(dataJson, standardUrl) ??
        Uri.parse(standardUrl).host.split('.').first;
    final newestUpload = uploads.first;
    final newestUploadBuild = _asMap(newestUpload['build']); // TODO: build is not always present
    final version = _versionForUpload(newestUpload) ?? // TODO: redo this
        _firstString(newestUploadBuild, ['version']) ??
        _parseDate(newestUpload['updated_at'])?.toIso8601String() ??
        'latest';
    final releaseDate = _parseDate(newestUpload['updated_at']) ??
        _parseDate(newestUploadBuild?['updated_at']);

    final apkLinks = <MapEntry<String, String>>[];
    for (final upload in uploads) {
      final uploadId = upload['id']?.toString();
      if (uploadId == null || uploadId.isEmpty) {
        _log('latest-details: skipping upload with missing id display_name=${upload['display_name']} filename=${upload['filename']}');
        continue;
      }
      final label = _labelForUpload(upload) ?? 'Android upload';
      // TODO: look into asset urls. Avoid using this problematic pseudoUrl since the app checks
      // assetUrl domains for user confirmation
      _log('latest-details: apk-link label=$label pseudoUrl=itchio-upload://$uploadId');
      apkLinks.add(MapEntry(label, 'itchio-upload://$uploadId'));
    }

    if (apkLinks.isEmpty) {
      _log('latest-details: no apk links built; falling back to scraper');
      return null;
    }

    _log('latest-details: success apkLinks=${apkLinks.length} title=$gameTitle author=$gameAuthor');
    return APKDetails(
      version,
      apkLinks,
      AppNames(gameAuthor, gameTitle),
      releaseDate: releaseDate,
      allAssetUrls: List<MapEntry<String, String>>.from(apkLinks),
    );
  }

  static String _uploadIdFromAssetUrl(String assetUrl) {
    // TODO: simplify this logic
    try {
      final uri = Uri.parse(assetUrl);
      if (uri.scheme == 'itchio-upload') {
        return uri.host.isNotEmpty
            ? uri.host
            : uri.pathSegments.isNotEmpty
                ? uri.pathSegments.last
                : throw FormatException('Invalid itchio-upload URL: $assetUrl');
      }
      String? match = RegExp(r'/upload/(\d+)(?:/download)?$').firstMatch(uri.path)?.group(1);
      if (match != null) {
        return match;
      }
    } catch (_) {
      // Ignore and fall back to the regex below.
    }
    final fallbackMatch = RegExp(r'(\d+)$').firstMatch(assetUrl);
    return fallbackMatch?.group(1) ?? (throw FormatException('Invalid asset URL: $assetUrl'));
  }

  static Future<String?> tryResolveAssetUrl({
    required AppSource source,
    required String assetUrl,
    required String standardUrl,
    required String apiKey,
    required Map<String, dynamic> additionalSettings,
  }) async {
    if (apiKey.isEmpty) {
      _log('asset-url: [ERROR] skip missing api key assetUrl=$assetUrl');
      return null;
    }

    String uploadId;
    try {
      uploadId = _ItchIoApiClient._uploadIdFromAssetUrl(assetUrl);
    } catch (err) {
      _log('asset-url: invalid assetUrl=$assetUrl error=$err');
      return null;
    }
    _log('asset-url: resolved uploadId=$uploadId from assetUrl=$assetUrl');

    final downloadEndpoint = _downloadEndpoint(apiKey, uploadId);
    _log('asset-url: request downloadEndpoint=$downloadEndpoint');
    var downloadRes = await source.sourceRequest(
      downloadEndpoint,
      additionalSettings,
    );
    if (downloadRes.statusCode != 200) {
      _log('asset-url: [ERROR] downloadEndpoint failed; falling back');
      return null;
    }

    // TODO: check all of this against real API responses
    // TODO: merge web scraper and API duplicated logic (e.g. version parsing)
    try {
      final body = jsonDecode(downloadRes.body);
      if (body is Map<String, dynamic>) {
        final url = body['url'] ?? body['download_url'] ?? body['direct_url'];
        _log('asset-url: decoded download field url=$url');
        return url?.toString();
      }
    } catch (_) {
      // Unexpected - ignore and fall back.
      _log('asset-url: [ERROR] json decode failed for download endpoint; falling back');
    }
    _log('asset-url: [ERROR] no usable url in response; falling back');
    return null;
  }
}


class _ItchIoWebScraper {
  /// Extracts the CSRF token from the page body (either from an input or JSON).
  static String? _findCsrf(String body) {
    RegExp csrfInputRegEx = RegExp(r'name="csrf_token" value="([^"]+)"');
    var match = csrfInputRegEx.firstMatch(body);
    if (match != null) return match.group(1);

    RegExp csrfJsonRegEx = RegExp(r'csrf_token":"([^"]+)"');
    match = csrfJsonRegEx.firstMatch(body);
    return match?.group(1);
  }

  /// Extracts all app titles and download IDs (upload_id or /download/ link IDs) from the page.
  ///
  /// The format of the element is the following:
  /// 1. Release name
  /// 2. Upload ID
  /// 3. Whether it is an Android download
  static List<(String, String, bool)> _extractDownload(String body) {
    var parser = parse(body);

    // Results containers
    List<(String, String, bool)> downloads = [];

    // It seems that in every spot, the download buttons are in this container.
    List<dom.Element> uploadDivs = parser.querySelectorAll('div.upload');

    if (uploadDivs.isNotEmpty) {
      for (var uploadDiv in uploadDivs) {
        // Extract the file ID
        dom.Element? nameDiv = uploadDiv.querySelector(
          'div.upload_name strong.name',
        );
        String uploadName = nameDiv?.attributes['title'] ?? 'App title';

        // OS Check
        bool osInfo =
            uploadDiv.querySelector(
              'span.download_platforms span.icon-android',
            ) !=
            null;

        // Try to extract the upload ID; fails if no download button
        var downloadButton = uploadDiv.querySelector('a.download_btn');
        String? uploadId = downloadButton?.attributes['data-upload_id'];

        if (uploadId != null) {
          downloads.add((uploadName, uploadId, osInfo));
        }
      }
    }
    return downloads;
  }

  /// Extracts the version string from the page body.
  ///
  /// Prioritizes info table data, then upload names, then 'Updated' date.
  ///
  /// This method has room for improvement; however, there is no defined
  /// standard on itch.io for declaring assets versions.
  static String? _parseVersion(dom.Document document) {
    // Limit our search to specific areas.
    // In the main page, use the section for the game information.
    String searchArea = document.querySelector("div.page_widget")!.innerHtml;

    List<String> supportedVersionStrings = [
      r'[vV](\d+\.\d+(?:\.\d+)*)',
      r'Version (\d+\.\d+(?:\.\d+)*)',
    ];
    Set<String> matches = {};

    for (var versionRegexString in supportedVersionStrings) {
      RegExp versionRegex = RegExp(versionRegexString);
      var regexMatches = versionRegex.allMatches(searchArea);
      for (var regexMatch in regexMatches) {
        matches.add(regexMatch.group(1)!);
      }
    }

    if (matches.isEmpty) return null;

    // Manual comparison, up to 3 digits
    int compareVersions(String v1, String v2) {
      List<int> c1 = v1.split('.').map(int.parse).toList();
      List<int> c2 = v2.split('.').map(int.parse).toList();
      for (int i = 0; i < 3; i++) {
        int p1 = i < c1.length ? c1[i] : 0;
        int p2 = i < c2.length ? c2[i] : 0;
        if (p1 != p2) return p1.compareTo(p2);
      }
      return 0;
    }

    return matches.reduce((a, b) => compareVersions(a, b) > 0 ? a : b);
  }

  /// Extracts the "Updated" date and formats it as YYYYMMDD for versioning.
  static String? _getDateVersion(dom.Document document) {
    // Check if we have any "abbr" dates. If not, exit early.
    List<dom.Element> abbrElements = document.querySelectorAll('abbr');
    if (abbrElements.isEmpty) return null;

    DateFormat abbrTimeFormat = DateFormat("dd MMMM yyyy '@' HH:mm 'UTC'");
    List<DateTime> abbrDates = [];
    for (var abbrElement in abbrElements) {
      DateTime abbrDate = abbrTimeFormat.parseUtc(
        abbrElement.attributes['title']!,
      );
      abbrDates.add(abbrDate);
    }

    DateTime dateTimeFilter(DateTime a, b) {
      return a.microsecondsSinceEpoch > b.microsecondsSinceEpoch ? a : b;
    }

    DateTime latest = abbrDates.reduce(dateTimeFilter);
    return '${latest.year}${latest.month}${latest.day}';
  }

  /// Extracts the app title from the page title.
  static String _parseTitle(dom.Document document) {
    String? title;
    dom.Element titleElement = document.getElementsByTagName('title')[0];
    title = titleElement.text;
    // The title is in format: GAMENAME by GAMEAUTHOR
    // Then, get just the first part
    return title.split(' by ').first.trim();
  }

  /// Resolves the app author from subdomain or author span.
  static String _parseAuthor(dom.Document document, String standardUrl) {
    dom.Element? followSpan = document.querySelector(
      'span.on_follow span.full_label',
    );
    var authorMatch = RegExp(r'Follow (.+)').firstMatch(followSpan!.text);
    String? author = authorMatch?.group(1)?.trim();
    return author ?? Uri.parse(standardUrl).host.split('.').first;
  }

  /// Internal method for retrieving CSRF token and cookies for multiple requests.
  static Future<(String?, String?)> _setupDownload(
    AppSource source,
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    final String baseUrl = standardUrl.replaceAll(RegExp(r'/$'), '');

    var warmUpRes = await source.sourceRequest(baseUrl, {...additionalSettings});
    if (warmUpRes.statusCode != 200) return (null, null);

    var csrfToken = _findCsrf(warmUpRes.body)!;
    var cookies = warmUpRes.headers['set-cookie']!;
    return (csrfToken, cookies);
  }

  /// Encapsulates the multi-step bypass flow to retrieve the download page body.
  static Future<String> _getDownloadPageBody(
    AppSource source,
    String standardUrl,
    Map<String, dynamic> additionalSettings,
    String initialBody,
    String? initialCsrfToken,
    String? initialCookies,
  ) async {
    // Start the setup
    final String baseUrl = standardUrl.replaceAll(RegExp(r'/$'), '');
    var currentBody = initialBody;

    String? csrfToken, cookies;

    if (initialCsrfToken != null && initialCookies != null) {
      (csrfToken, cookies) = (initialCsrfToken, initialCookies);
    } else {
      (csrfToken, cookies) = await _setupDownload(
        source,
        standardUrl,
        additionalSettings,
      );
    }

    // Easy case: download buttons are on the first page.
    // All next if checks are skipped.
    var ids = _extractDownload(currentBody);

    // No buttons have been found, we need to "purchase"
    if (ids.isEmpty) {
      // Step 1: POST to /download_url bypass (e.g. for "Name your price")
      var bypassRes = await source.sourceRequest(
        '$baseUrl/download_url',
        {
          ...additionalSettings,
          'extraHeaders': {
            'X-Requested-With': 'XMLHttpRequest',
            if (cookies != null) 'Cookie': cookies,
          },
        },
        postBody: {'csrf_token': csrfToken},
      );
      if (bypassRes.statusCode == 200) {
        // The call returns a JSON like: {"url":"download_url"}
        var tokenizedUrl = jsonDecode(bypassRes.body)['url'] as String?;
        if (tokenizedUrl != null) {
          // We are now in GAME_URL/download/HASH
          var downloadPageRes = await source.sourceRequest(tokenizedUrl, {
            ...additionalSettings,
            'extraHeaders': {if (cookies != null) 'Cookie': cookies},
          });
          if (downloadPageRes.statusCode == 200) {
            // We are now at the download page, with shiny buttons
            currentBody = downloadPageRes.body;
          }
        }
      }
    }

    return currentBody;
  }

  static Future<APKDetails> tryGetLatestAPKDetails(
    AppSource source,
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    final String baseUrl = standardUrl.replaceAll(RegExp(r'/$'), '');

    // Retrieve the body for parsing
    var res = await source.sourceRequest(standardUrl, additionalSettings);
    if (res.statusCode != 200) {
      throw getObtainiumHttpError(res);
    }
    var body = res.body;

    // Retrieve CSRF token and cookies
    var (csrfToken, cookies) = await _setupDownload(
      source,
      standardUrl,
      additionalSettings,
    );

    // Metadata extraction
    dom.Document storePage = parse(body);
    String title = _parseTitle(storePage);
    String author = _parseAuthor(storePage, standardUrl);
    String? dateVersion = _getDateVersion(storePage);
    String? version = _parseVersion(storePage);

    // Resolve tokenized download page
    String downloadPageBody = await _getDownloadPageBody(
      source,
      standardUrl,
      additionalSettings,
      body,
      csrfToken,
      cookies,
    );

    // Fetch better version from the download page, if any
    dom.Document downloadPage = parse(downloadPageBody);
    dateVersion ??= _getDateVersion(downloadPage);
    version ??= _parseVersion(downloadPage);

    // Rules for defaulting the version
    // 1. Nice version, if found
    // 2. Date of last update
    // 3. Fallback to 'latest'
    version = version ?? dateVersion ?? 'latest';

    // Create all relevant APK links
    List<MapEntry<String, String>> apkLinks = [];
    var downloadIds = _extractDownload(downloadPageBody);

    for (var downloadInfo in downloadIds) {
      var (name, id, isAndroid) = downloadInfo;
      if (isAndroid) {
        // Try retrieving the correct file
        var realName = await _resolveRealFileName(
          source,
          id,
          standardUrl,
          additionalSettings,
          csrfToken,
          cookies,
        );
        // Use the real name if possible, otherwise fallback to the one on the page.
        var label = realName ?? name;
        apkLinks.add(MapEntry(label, '$baseUrl/download/$id'));
      }
    }

    if (apkLinks.isEmpty) throw NoAPKError();
    return APKDetails(version, apkLinks, AppNames(author, title));
  }

  /// Internal method for finding the correct Cloudflare R2 URL for any given asset.
  static Future<String?> _retrieveCloudflareUrl(
    AppSource source,
    String uploadId,
    String standardUrl,
    Map<String, dynamic> additionalSettings,
    String? csrfToken,
    String? cookies,
  ) async {
    final String baseUrl = standardUrl.replaceAll(RegExp(r'/$'), '');

    if (csrfToken == null || cookies == null) {
      (csrfToken, cookies) = await _setupDownload(
        source,
        standardUrl,
        additionalSettings,
      );
    }

    var fileApiUrl = '$baseUrl/file/$uploadId?as_props=1&source=game_download';
    var downloadRequestRes = await source.sourceRequest(
      fileApiUrl,
      {
        ...additionalSettings,
        'extraHeaders': {
          'X-Requested-With': 'XMLHttpRequest',
          'Referer': '$baseUrl/download/$uploadId',
          if (cookies != null) 'Cookie': cookies,
        },
      },
      postBody: {'csrf_token': csrfToken},
    );

    if (downloadRequestRes.statusCode != 200) return null;

    // This is a JSON with the url within
    return jsonDecode(downloadRequestRes.body)['url'] as String?;
  }

  /// Resolves the real filename of an asset by following the download flow.
  ///
  /// This retrieves the direct download URL (often Cloudflare R2) and
  /// extracts the filename from the Content-Disposition header.
  static Future<String?> _resolveRealFileName(
    AppSource source,
    String uploadId,
    String standardUrl,
    Map<String, dynamic> additionalSettings,
    String? csrfToken,
    String? cookies,
  ) async {
    var directUrl = await _retrieveCloudflareUrl(
      source,
      uploadId,
      standardUrl,
      additionalSettings,
      csrfToken,
      cookies,
    );

    if (directUrl == null) return null;

    final String baseUrl = standardUrl.replaceAll(RegExp(r'/$'), '');
    var streamRes = await sourceRequestStreamResponse('GET', directUrl, {
      'Referer': '$baseUrl?download',
    }, additionalSettings);

    // Peek into the Content-Disposition header
    var response = streamRes.value.value;
    var cd = response.headers.value('content-disposition');
    streamRes.value.key.close(force: true);

    if (cd == null) return null;

    var match = RegExp(r'filename="?([^";]+)"?').firstMatch(cd);
    return match?.group(1);
  }

  /// Custom itch.io URL fetcher.
  ///
  /// Since the filehost is on Cloudflare R2, we need to resolve the asset URL
  /// after we identified the download.
  static Future<String?> tryResolveAssetUrl(
    AppSource source,
    String assetUrl,
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    // We store the upload ID in the last chunk of the URL.
    // We can then use it to retrive the Cloudflare R2 real URL.
    var uploadId = assetUrl.split('/').last;
    // TODO: maybe merge logic with API client

    String? cloudFlareUrl = await _retrieveCloudflareUrl(
      source,
      uploadId,
      standardUrl,
      additionalSettings,
      // We are outside of regular fetching, so we need fresh cookies and token
      null,
      null,
    );

    if (cloudFlareUrl != null) return cloudFlareUrl;

    return assetUrl;
  }
}
