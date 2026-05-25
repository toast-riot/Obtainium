import 'dart:convert';
import 'dart:io';
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
        additionalValidators: [ // TODO: test
          (value) {
            if (value != null && value.isNotEmpty &&
                !RegExp(r'^[A-Za-z0-9]{40}$').hasMatch(value)) {
              return tr('invalidInput');
            }
            return null;
          },
        ],
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
    if (apiKey != null && Uri.tryParse(url)?.host == _ItchIoApiClient._host) {
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
      try {
        return await _ItchIoApiClient.tryGetLatestAPKDetails(
          source: this,
          standardUrl: standardUrl,
          additionalSettings: additionalSettings,
        );
      } on APIError catch (e) {
        if (!e.shouldFallBack) rethrow;
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
      try {
        return await _ItchIoApiClient.tryResolveAssetUrl(
          source: this,
          assetUrl: assetUrl,
          standardUrl: standardUrl,
          additionalSettings: additionalSettings,
        );
      } on APIError catch (e) {
        if (!e.shouldFallBack) rethrow;
      }
    }

    return await _ItchIoWebScraper.tryResolveAssetUrl(
      this,
      assetUrl,
      standardUrl,
      additionalSettings,
    );
  }
}

class _APIGame {
  final String id;
  final String title;
  final List<String> authors;

  _APIGame({
    required this.id,
    required this.title,
    required this.authors,
  });

  factory _APIGame.fromJson(Map<String, dynamic> json) {
    // preferring fail-fast since in theory these fields are always present and correctly typed
    // if not, we want to know immediately and fix the parsing logic, rather than silently returning wrong data
    final id = json['id'].toString();
    final title = json['title'] as String;
    final authors = (json['authors'] as List)
      .map((a) => a['name'] as String)
      .toList();

    return _APIGame(id: id, title: title, authors: authors);
  }
}

class _APIUpload {
  final int id;
  final String filename;
  final String? displayName;
  final List<String> traits;
  // final String storage;
  // final int size;
  // final _build?;
  // final String? type;
  // final DateTime createdAt;
  final DateTime updatedAt;

  bool get isAndroid {
    final fn = filename.toLowerCase();
    return (
      fn.endsWith('.apk') || fn.endsWith('.xapk') ||
      (fn.endsWith('.zip') && traits.contains('p_android'))
    );
  }

  _APIUpload({
    required this.id,
    required this.filename,
    required this.displayName,
    required this.traits,
    required this.updatedAt,
  });

  factory _APIUpload.fromJson(Map<String, dynamic> json) {
    // if no traits are present, they get interpreted as a map for some reason
    final rawTraits = json['traits'];
    final List<String> traits = (rawTraits is Map && rawTraits.isEmpty) ?
      <String>[] : List<String>.from(rawTraits);

    return _APIUpload(
      id: json['id'] as int,
      filename: json['filename'] as String,
      displayName: json['display_name'] as String?,
      traits: traits,
      updatedAt: DateTime.parse(json['updated_at']),
    );
  }
}


class _Common {
}

class APIError implements Exception {
  final String message;
  final bool shouldFallBack;

  APIError(
    this.message, {
    this.shouldFallBack = true,
    // shouldFallBack is set to false only when the error is something user-related,
    // in which case the scraper would run into the same issue (e.g. no compatible uploads)
  });

  @override
  String toString() => 'itch.io API Error: $message';
}

class _ItchIoApiClient {
  static const _host = 'api.itch.io';
  static final _endpoint = Uri.parse('https://$_host');

  // TODO: build is not always present, and filename is not always a good version indicator
  // fallbacks that might work: 'md5_hash', 'updated_at', 'id' (which is incremental and therefore unique but global and not per-game)
  // static String? _versionForUpload(Map<String, dynamic> upload) {
  //   final build = _asMap(upload['build']); // TODO: not always present
  //   return _firstString(build, ['user_version']) ??
  //       _firstString(upload, ['filename']);
  // }

  static Future<APKDetails> tryGetLatestAPKDetails({
    required AppSource source,
    required String standardUrl,
    required Map<String, dynamic> additionalSettings,
  }) async {
    final baseUrl = Uri.parse(standardUrl);

    // for title and author, https://api.itch.io/games/<GAME-ID> would probably be better, but this avoids extra requests
    final dataRes = await source.sourceRequest(
      '$standardUrl/data.json',
      additionalSettings,
    );
    if (dataRes.statusCode != 200) throw getObtainiumHttpError(dataRes);

    final dataJson = jsonDecode(dataRes.body);
    final game = _APIGame.fromJson(dataJson);

    // get uploads
    final uploadsRes = await source.sourceRequest(
      _endpoint.resolve('games/${game.id}/uploads').toString(),
      additionalSettings,
    );
    if (uploadsRes.statusCode != 200) throw getObtainiumHttpError(uploadsRes);
    final uploadsJson = jsonDecode(uploadsRes.body);
    final List<_APIUpload> allUploads = (uploadsJson['uploads'] as List)
      .map((e) => _APIUpload.fromJson(e))
      .toList();

    if (allUploads.isEmpty) throw APIError('No uploads found for game ID ${game.id}', shouldFallBack: false);
    final uploads = allUploads.where((u) => u.isAndroid).toList();
    if (uploads.isEmpty) throw APIError('No uploads were Android-compatible for game ID ${game.id}', shouldFallBack: false);

    // TODO: the main upside here is that itch.io *only* provides the latest download, removing the need to determine which version is latest
    // however, there might be multiple downloads deemed relevant, e.g. an apk and a save file (as a .zip marked as p_android)
    // of course, both can be returned, and the user is then asked to choose which to download; however,
    // each upload has its own version, and we need to return a version before the user is prompted to choose a release
    uploads.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final newestUpload = uploads.first;
    // final newestUploadBuild = _asMap(newestUpload['build']); // TODO: build is not always present (but is very useful for determining version)
    // final version = _versionForUpload(newestUpload) ?? // TODO: redo this
    //     _firstString(newestUploadBuild, ['version']) ??
    //     _tryParseDate(newestUpload['updated_at'])?.toIso8601String() ??
    //     'latest';
    final releaseDate = newestUpload.updatedAt;

    final apkLinks = <MapEntry<String, String>>[];
    for (final upload in uploads) {
      final label = upload.displayName ?? upload.filename;
      apkLinks.add(MapEntry(label, baseUrl.resolve('download/${upload.id}').toString()));
    }

    if (apkLinks.isEmpty) throw NoAPKError();

    return APKDetails(
      version,
      apkLinks,
      AppNames(game.authors.join(', '), game.title),
      releaseDate: releaseDate,
      allAssetUrls: List<MapEntry<String, String>>.from(apkLinks),
    );
  }

  static Future<String> tryResolveAssetUrl({
    required AppSource source,
    required String assetUrl,
    required String standardUrl,
    required Map<String, dynamic> additionalSettings,
  }) async {
    throw APIError('Not yet implemented', shouldFallBack: true);

    String uploadId = Uri.parse(assetUrl).pathSegments.last;

    var downloadRes = await source.sourceRequest(
      _endpoint.resolve('uploads/$uploadId/download').toString(),
      additionalSettings,
    );
    if (downloadRes.statusCode != 200) { throw getObtainiumHttpError(downloadRes); }
    
    // TODO: check all of this against real API responses
    // TODO: merge web scraper and API duplicated logic (version parsing, download url handling)
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
    var warmUpRes = await source.sourceRequest(standardUrl, {...additionalSettings});
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
    final baseUrl = Uri.parse(standardUrl);
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
        baseUrl.resolve('download_url').toString(),
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
    final baseUrl = Uri.parse(standardUrl);

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
        apkLinks.add(MapEntry(label, baseUrl.resolve('download/$id').toString()));
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
    final baseUrl = Uri.parse(standardUrl);

    if (csrfToken == null || cookies == null) {
      (csrfToken, cookies) = await _setupDownload(
        source,
        standardUrl,
        additionalSettings,
      );
    }

    final fileApiUrl = baseUrl.resolve('file/$uploadId?as_props=1&source=game_download');
    final downloadRequestRes = await source.sourceRequest(
      fileApiUrl.toString(),
      {
        ...additionalSettings,
        'extraHeaders': {
          'X-Requested-With': 'XMLHttpRequest',
          'Referer': baseUrl.resolve('download/$uploadId').toString(),
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

    final baseUrl = Uri.parse(standardUrl);
    var streamRes = await sourceRequestStreamResponse('GET', directUrl, {
      'Referer': baseUrl.resolve('download').toString(),
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
  static Future<String> tryResolveAssetUrl(
    AppSource source,
    String assetUrl,
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    // We store the upload ID in the last chunk of the URL.
    // We can then use it to retrive the Cloudflare R2 real URL.
    String uploadId = Uri.parse(assetUrl).pathSegments.last;

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

    return assetUrl; // TODO: this should probably throw
  }
}
