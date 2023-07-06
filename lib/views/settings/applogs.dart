import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:get/get.dart';
import 'package:invidious/controllers/appLogsController.dart';

import '../../globals.dart';
import '../../main.dart';
import '../../models/db/appLog.dart';

class AppLogs extends StatelessWidget {
  const AppLogs({super.key});

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    ColorScheme colors = Theme.of(context).colorScheme;

    return GetBuilder<AppLogsController>(
      global: false,
      init: AppLogsController(),
      builder: (_) =>Scaffold(
      appBar: AppBar(
        title: Text(locals.appLogs),
        actions: [
          IconButton(onPressed: _.selectAll, icon: const Icon(Icons.checklist))
        ],
      ),
      body: SafeArea(
        bottom: false,
        child:  Stack(
            children: [
              AnimatedPositioned(
                duration: animationDuration,
                left: 0,
                right: 0,
                top: 0,
                bottom: _.selected.isNotEmpty ? 50 : 0,
                child: ListView.separated(
                  itemCount: _.logs.length,
                  itemBuilder: (context, index) {
                    AppLog log = _.logs[index];
                    return CheckboxListTile(
                      title: Text(
                        '${log.level ?? ''} - ${log.logger} - ${log.time}',
                        style: TextStyle(fontSize: 10, color: colors.secondary),
                      ),
                      subtitle: Text('${log.message}${log.stacktrace != null ? '\n\n${log.stacktrace}' : ''}'),
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      value: _.selected.contains(log.id),
                      onChanged: (bool? value) => _.selectLog(log.id, value),
                    );
                  },
                  separatorBuilder: (BuildContext context, int index) {
                    return const Divider();
                  },
                ),
              ),
              AnimatedPositioned(
                  left: 0,
                  right: 0,
                  bottom: _.selected.isNotEmpty ? 0 : -50,
                  duration: animationDuration,
                  child: InkWell(
                    onTap: () {
                      _.copySelectedLogsToClipboard();
                      final ScaffoldMessengerState? scaffold = scaffoldKey.currentState;
                      scaffold?.showSnackBar(SnackBar(
                        content: Text(locals.logsCopied),
                        duration: const Duration(seconds: 1),
                      ));
                    },
                    child: Container(
                      alignment: Alignment.center,
                      height: 50,
                      color: colors.secondaryContainer,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(right: 8.0),
                            child: Icon(
                              Icons.copy,
                              size: 15,
                            ),
                          ),
                          Text(locals.copyToClipBoard),
                        ],
                      ),
                    ),
                  ))
            ],
          ),
        ),
      ),
    );
  }
}