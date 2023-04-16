import 'package:flutter/material.dart';

class AddSite extends StatefulWidget {
  @override
  _AddSiteState createState() => _AddSiteState();
}

class _AddSiteState extends State<AddSite> {
  final TextEditingController _controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Add new site'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(labelText: 'Enter website URL'),
            ),
            ElevatedButton(
              onPressed: () {
                String url = _controller.text.trim();
                if (!url.startsWith('http://') && !url.startsWith('https://')) {
                  url = 'https://$url';
                }
                Navigator.pop(context, url);
              },
              child: Text('Add site'),
            ),
          ],
        ),
      ),
    );
  }
}
