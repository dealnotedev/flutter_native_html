// ESP classification of Common Crawl captures by URL (host/path/query).
// Returns null for URLs that are certainly not a single sent campaign.

function q(rec) {
  const s = rec.url_query || '';
  return new URLSearchParams(s.startsWith('?') ? s.slice(1) : s);
}

function seg(rec) {
  return (rec.url_path || '/').split('/').filter(Boolean);
}

export const ESPS = ['mailchimp', 'campaignmonitor', 'kit', 'emailoctopus', 'mailerlite', 'klaviyo', 'brevo', 'constantcontact', 'mailjet', 'flodesk', 'getresponse', 'aweber'];

/** @returns {{esp:string, sender:string|null, campaign:string}|null} */
export function classify(rec) {
  const host = (rec.url_host_name || '').toLowerCase();
  const dom = rec.url_host_registered_domain;
  const path = rec.url_path || '/';
  const params = q(rec);
  const s = seg(rec);

  switch (dom) {
    case 'campaign-archive.com':
    case 'campaign-archive1.com':
    case 'campaign-archive2.com': {
      // https://us5.campaign-archive.com/?u=<account>&id=<campaign>
      if (/^\/(home|feed|generate-js|js|css|images)\b/.test(path)) return null;
      const u = params.get('u');
      const id = params.get('id');
      if (!u || !id) return null;
      // e=<subscriber> marks a personalised copy (opened from a sent email).
      return { esp: 'mailchimp', sender: `u:${u}`, campaign: id, personal: params.has('e') };
    }
    case 'mailchi.mp': {
      // https://mailchi.mp/<account-or-hash>/<campaign-slug>; also custom subdomains <brand>.mailchi.mp/<slug>
      if (host === 'mailchi.mp' || host === 'www.mailchi.mp') {
        if (s.length !== 2) return null;
        return { esp: 'mailchimp', sender: `mp:${s[0]}`, campaign: s[1] };
      }
      if (s.length < 1) return null;
      return { esp: 'mailchimp', sender: `mp:${host}`, campaign: s.join('/') };
    }
    case 'createsend.com':
    case 'createsend1.com':
    case 'cmail1.com':
    case 'cmail2.com':
    case 'cmail19.com':
    case 'cmail20.com': {
      // Public share link of the web version: https://createsend.com/t/d-<CAMPAIGNID>
      let m = /^\/t\/d-([A-F0-9]{8,})\/?$/i.exec(path);
      if (m) return { esp: 'campaignmonitor', sender: null, campaign: m[1] };
      // "View in browser": https://<acct>.createsend1.com/t/ViewEmail/r/<campaign>/<subscriber>
      m = /\/t\/ViewEmail(?:Archive)?\/[a-z]\/([A-Z0-9]+)/i.exec(path);
      if (m) return { esp: 'campaignmonitor', sender: host.split('.').length > 2 ? `host:${host}` : null, campaign: m[1], personal: true };
      return null;
    }
    case 'ckarchive.com':
      // https://ckarchive.com/b/<id>  (Kit "view in browser")
      if (s[0] !== 'b' || s.length < 2) return null;
      return { esp: 'kit', sender: null, campaign: s[1] };
    case 'convertkit-mail.com':
    case 'convertkit-mail2.com':
      return null; // click/open tracking hosts
    case 'ck.page':
    case 'kit.com':
      // <creator>.kit.com/posts/<slug> and <creator>.ck.page/posts/<slug> are creator-profile
      // web pages (Kit site chrome, Tailwind React app) that re-render the post body; they are
      // not the sent email HTML, so they are not collected. ck.page/<id> are landing pages/forms.
      return null;
    case 'eocampaign1.com':
      // https://eocampaign1.com/web-version?p=<campaign uuid>&pt=campaign&t=..&s=..
      if (!/web-version|^\/preview\b/.test(path)) return null;
      if (params.get('pt') && params.get('pt') !== 'campaign') return null;
      return { esp: 'emailoctopus', sender: null, campaign: params.get('p') || path, personal: params.has('lc') || params.has('ep') };
    case 'mailerlite.com':
    case 'mailerlite.io':
    case 'mlsend.com':
    case 'mlsend2.com':
    case 'mailerlite.co': {
      if (!/^preview\./.test(host)) return null; // www.mailerlite.com/a/<id> are affiliate redirects
      // preview.mailerlite.io/preview/<account>/emails/<id>  (public campaign preview)
      if (s[0] === 'preview' && s[2] === 'emails' && s.length >= 4) return { esp: 'mailerlite', sender: `acct:${s[1]}`, campaign: s[3] };
      // preview.mailerlite.io/emails/webview/<account>/<id>
      if (s[0] === 'emails' && s[1] === 'webview' && s.length >= 4) return { esp: 'mailerlite', sender: `acct:${s[2]}`, campaign: s[3] };
      // preview.mailerlite.com/<campaign code>/<subscriber id>/<hash>/ : per-subscriber copy
      if (host === 'preview.mailerlite.com' && s.length >= 3 && /^\d{10,}$/.test(s[1])) return { esp: 'mailerlite', sender: `code:${s[0]}`, campaign: s[0], personal: true };
      // .../sites/..., .../forms/..., /webforms/... are landing pages and signup forms.
      return null;
    }
    case 'klaviyo.com':
    case 'kmail-lists.com':
    case 'klaviyomail.com': {
      // "View in browser": https://manage.kmail-lists.com/subscriptions/web-view?a=..&c=..
      // (always recipient-specific: k=/r=/m= tokens; kept but marked personal)
      if (/\/subscriptions\/web-view/.test(path)) return { esp: 'klaviyo', sender: params.get('a') ? `a:${params.get('a')}` : null, campaign: params.get('c') || rec.url_query || path, personal: true };
      return null;
    }
    case 'sendinblue.com':
    case 'brevo.com':
    case 'sendibt2.com':
    case 'sendibt3.com':
    case 'sendibm1.com':
    case 'sendibm2.com':
    case 'brevosend.com':
    case 'sendib.com': {
      // Mirror / share links: https://<x>.r.<y>.sendibt3.com/mk/mr/sh/<token>  ;  /mk/mr/<token>
      if (!/\/mk\/mr\//.test(path)) return null;
      return { esp: 'brevo', sender: null, campaign: path };
    }
    case 'constantcontact.com': {
      // https://myemail.constantcontact.com/<Title>.html?soid=<account>&aid=<campaign>
      if (/^myemail\./.test(host)) {
        const soid = params.get('soid');
        if (!soid) return null;
        return { esp: 'constantcontact', sender: `soid:${soid}`, campaign: params.get('aid') || path };
      }
      // Legacy archive: http://archive.constantcontact.com/fs123/<soid>/archive/<aid>.html
      if (/^archive\./.test(host) && s.length >= 4 && s[2] === 'archive' && /\.html$/.test(s[3])) {
        return { esp: 'constantcontact', sender: `soid:${s[1]}`, campaign: s[3] };
      }
      return null;
    }
    case 'mjt.lu':
      // https://<x>.mjt.lu/nl2/<x>/<y>.html (Mailjet "view online")
      if (!/^\/nl\d?\//.test(path)) return null;
      return { esp: 'mailjet', sender: `host:${host}`, campaign: path };
    case 'flodesk.com':
      // https://view.flodesk.com/emails/<id>  (view.flodesk.com/pages/* are landing pages/forms)
      if (host !== 'view.flodesk.com' || s[0] !== 'emails' || s.length < 2) return null;
      return { esp: 'flodesk', sender: null, campaign: s[1] };
    case 'getresponse.com':
      // https://www.getresponse.com/archive/<account>/<Title>-<id>.html
      if (s[0] !== 'archive' || s.length < 3) return null;
      return { esp: 'getresponse', sender: `acct:${s[1]}`, campaign: s.slice(2).join('/') };
    case 'aweber.com':
      // archive.aweber.com/newsletter/<list>/<id>/<slug>.htm pages re-wrap only a body fragment of
      // the message in AWeber's "newsletter hub" site (header/nav/footer, toolkit CSS); there is no
      // complete email document to recover, so they are not collected (see strip.mjs too).
      return null;
    default:
      return null;
  }
}
