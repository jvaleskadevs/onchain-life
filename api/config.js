export default function handler(req, res) {
  res.setHeader('Content-Type', 'application/json');
  res.status(200).json({ 
    rpcUrl: process.env.SEPOLIA_RPC_URL 
  });
}
