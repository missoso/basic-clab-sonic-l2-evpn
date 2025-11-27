echo "pings from client 1"
docker exec client1 ping -c 2 10.10.10.2

echo "pings from client 2"
docker exec client2 ping -c 2 10.10.10.2