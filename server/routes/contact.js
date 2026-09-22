const express = require('express');
const nodemailer = require('nodemailer');
const db = require('../db');

const router = express.Router();

let transporter = null;
function getTransporter() {
  if (transporter) return transporter;
  if (!process.env.SMTP_HOST) return null;
  transporter = nodemailer.createTransport({
    host: process.env.SMTP_HOST,
    port: Number(process.env.SMTP_PORT || 587),
    secure: process.env.SMTP_SECURE === 'true',
    auth: process.env.SMTP_USER ? { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS } : undefined
  });
  return transporter;
}

// Egypt -> info@impactegypt.com. Everything else (UAE, KSA, any other
// Middle East / international country) -> info@impact-ld.me.
function routeByCountry(country) {
  const normalized = String(country || '').trim().toLowerCase();
  const isEgypt = normalized === 'eg' || normalized === 'egy' || normalized.includes('egypt') || normalized.includes('مصر');
  return isEgypt
    ? (process.env.MAIL_TO_EGYPT || 'info@impactegypt.com')
    : (process.env.MAIL_TO_DEFAULT || 'info@impact-ld.me');
}

router.post('/', async (req, res) => {
  const body = req.body || {};
  const {
    inquiryType = '', name = '', email = '', company = '', role = '',
    country = '', serviceInterest = '', budget = '', timeline = '', message = ''
  } = body;

  if (!name.trim() || !country.trim() || !message.trim()) {
    return res.status(400).json({ error: 'Name, country, and message are required.' });
  }

  const routedTo = routeByCountry(country);

  const lines = [
    `Inquiry type: ${inquiryType || 'General'}`,
    `Name: ${name}`,
    `Email: ${email}`,
    `Company: ${company}`,
    `Role: ${role}`,
    `Country: ${country}`,
    `Service interest: ${serviceInterest}`,
    `Budget: ${budget}`,
    `Timeline: ${timeline}`,
    '',
    'Message:',
    message
  ];
  const textBody = lines.join('\n');
  const subject = `New inquiry — ${inquiryType || 'Website contact form'}${company ? ' — ' + company : ''}`;

  let emailSent = 0;
  let emailError = null;

  const mailer = getTransporter();
  if (!mailer) {
    emailError = 'SMTP is not configured (set SMTP_HOST/SMTP_USER/SMTP_PASS in .env)';
  } else {
    try {
      await mailer.sendMail({
        from: process.env.MAIL_FROM || 'Impact Website <no-reply@impactegypt.com>',
        to: routedTo,
        replyTo: email || undefined,
        subject,
        text: textBody
      });
      emailSent = 1;
    } catch (err) {
      emailError = err.message;
    }
  }

  db.prepare(`
    INSERT INTO contact_submissions
      (inquiry_type, name, email, company, role, country, service_interest, budget, timeline, message, routed_to, email_sent, email_error)
    VALUES (@inquiryType, @name, @email, @company, @role, @country, @serviceInterest, @budget, @timeline, @message, @routedTo, @emailSent, @emailError)
  `).run({ inquiryType, name, email, company, role, country, serviceInterest, budget, timeline, message, routedTo, emailSent, emailError });

  if (!emailSent) {
    // Submission is saved either way (visible in the admin), but tell the
    // client if the live email didn't actually go out.
    return res.status(502).json({ ok: false, error: emailError, routedTo });
  }
  res.json({ ok: true, routedTo });
});

module.exports = router;
