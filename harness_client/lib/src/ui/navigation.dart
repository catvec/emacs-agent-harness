import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'adaptive/platform_style.dart';

Route<T> harnessRoute<T>(BuildContext context, WidgetBuilder builder) {
  if (HarnessStyle.isCupertino(context)) {
    return CupertinoPageRoute<T>(builder: builder);
  }
  return MaterialPageRoute<T>(builder: builder);
}
