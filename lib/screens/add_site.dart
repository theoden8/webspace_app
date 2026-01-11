import 'package:flutter/material.dart';

class AddSiteScreen extends StatefulWidget {
  @override
  _AddSiteScreenState createState() => _AddSiteScreenState();
}

class _AddSiteScreenState extends State<AddSiteScreen> {
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
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(labelText: 'Enter website URL'),
            ),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                String url = _controller.text.trim();
                // If no protocol specified, default to https
                if (!url.startsWith('http://') && !url.startsWith('https://')) {
                  url = 'https://$url';
                }
                Navigator.pop(context, url);
              },
              child: Text('Add Site'),
            ),
            SizedBox(height: 8),
            Text(
              'Tip: Type http:// for HTTP sites, or just the domain for HTTPS',
              style: TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
