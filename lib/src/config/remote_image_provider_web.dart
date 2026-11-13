import 'package:flutter/painting.dart';

ImageProvider remoteImageProvider(Uri uri, int maxBytes) =>
    NetworkImage(uri.toString());
