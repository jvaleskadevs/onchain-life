export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const routerUrl = process.env.GAS_KILLER_ROUTER_URL;
  const apiKey = process.env.GAS_KILLER_API_KEY;
  
  if (!routerUrl || !apiKey) {
    return res.status(500).json({ error: 'Server configuration error' });
  }

  const body = req.body;
  
  try {
    const response = await fetch(`${routerUrl}/tasks`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ body }),
    });
    
    const data = await response.json();
    res.status(response.status).json(data);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
}
