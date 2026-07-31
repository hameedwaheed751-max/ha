const {onRequest} = require("firebase-functions/v2/https");

exports.sasProxy = onRequest(async (req, res) => {
  res.json({
    ok: true,
    message: "NetAgent SAS Proxy is working",
  });
});