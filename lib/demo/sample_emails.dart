/// A demo email sample (title + raw HTML body) for the showcase screen.
class SampleEmail {
  const SampleEmail(this.title, this.html);
  final String title;
  final String html;
}

/// Representative email bodies exercising the renderer's features.
const List<SampleEmail> kSampleEmails = [
  SampleEmail('Basic formatting', _basic),
  SampleEmail('Inline & <style> CSS', _styled),
  SampleEmail('Lists', _lists),
  SampleEmail('Table layout (newsletter)', _table),
  SampleEmail('Images (inline + blocked)', _images),
  SampleEmail('Sanitization (script stripped)', _unsafe),
];

const _basic = '''
<h1>Welcome aboard 🎉</h1>
<p>Hi Alex,</p>
<p>Thanks for signing up. Here is what you can do <b>right now</b>:</p>
<p>Read the <a href="https://example.com/docs">documentation</a>, or jump
straight into the <i>getting started</i> guide. You can always reach us at
<a href="mailto:support@example.com">support@example.com</a>.</p>
<blockquote>"The journey of a thousand miles begins with a single step."</blockquote>
<p>Cheers,<br>The Team</p>
<hr>
<p style="font-size:12px;color:#888">You received this email because you
registered an account. <a href="https://example.com/unsubscribe">Unsubscribe</a>.</p>
''';

const _styled = '''
<html><head><style>
  body { font-family: Georgia, serif; color: #2b2b2b; }
  .card { background: #f4f6fb; padding: 16px; border: 1px solid #d6dcea; }
  .badge { background: #1565c0; color: #ffffff; padding: 2px 8px; font-size: 12px; }
  h2 { color: #1565c0; }
  .muted { color: #8a8a8a; font-size: 13px; }
  a { color: #c62828; }
</style></head><body>
  <div class="card">
    <span class="badge">NEW</span>
    <h2>Your weekly summary</h2>
    <p>You completed <b style="color:#2e7d32">12 tasks</b> this week — a personal best!</p>
    <p style="text-align:center; background:#fff; padding:10px;">
      <a href="https://example.com/report">View full report &rarr;</a>
    </p>
    <p class="muted">Stats are computed every Monday at 09:00 UTC.</p>
  </div>
</body></html>
''';

const _lists = '''
<h3>Shopping list</h3>
<ul>
  <li>Milk</li>
  <li>Eggs
    <ul>
      <li>Free-range</li>
      <li>Size: large</li>
    </ul>
  </li>
  <li>Bread</li>
</ul>
<h3>Steps</h3>
<ol type="1">
  <li>Preheat the oven to 200&deg;C.</li>
  <li>Mix the dry ingredients.</li>
  <li>Bake for 25 minutes.</li>
</ol>
''';

const _table = '''
<table width="100%" cellpadding="12" bgcolor="#0d47a1">
  <tr>
    <td align="center">
      <font color="#ffffff" size="5"><b>ACME Weekly</b></font>
    </td>
  </tr>
</table>
<table width="100%" cellpadding="12">
  <tr>
    <td width="60%" valign="top">
      <h3 style="margin-top:0">Headline story</h3>
      <p>A short teaser paragraph describing the most important update of the
      week, with a <a href="https://example.com/story">read more</a> link.</p>
    </td>
    <td width="40%" valign="top" bgcolor="#f0f4ff">
      <b>In brief</b>
      <p style="font-size:13px;margin:4px 0">• Release 2.1 is out<br>
      • New dashboard<br>
      • Bug fixes</p>
    </td>
  </tr>
</table>
<table width="100%" border="1" cellpadding="8">
  <tr bgcolor="#eeeeee"><th>Plan</th><th>Price</th><th>Seats</th></tr>
  <tr><td>Starter</td><td>\$9</td><td>1</td></tr>
  <tr><td>Team</td><td>\$29</td><td>5</td></tr>
  <tr><td>Business</td><td>\$99</td><td>25</td></tr>
</table>
''';

// A 1x1 transparent PNG as an inline data: image, plus a remote (blocked) one.
const _images = '''
<h3>Inline image (data URI)</h3>
<p>This pixel loads inline, no network:
<img alt="dot" width="24" height="24"
src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="></p>
<h3>Remote image (blocked by default)</h3>
<p>This one is suppressed for privacy until the user opts in:</p>
<img alt="A remote banner image" src="https://example.com/banner.png" width="320" height="80">
''';

const _unsafe = '''
<h3>This email tries to be sneaky</h3>
<p onclick="alert('xss')">Tapping this paragraph does nothing — the handler was stripped.</p>
<script>window.location='https://evil.example';</script>
<p>A link with a javascript: URL is neutralized:
<a href="javascript:alert(1)">click me</a></p>
<p>But normal content renders fine: <b>bold</b>, <i>italic</i>, and a safe
<a href="https://example.com">link</a>.</p>
''';
