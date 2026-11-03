// Recipe: tcp server and client: tcp::listen, accept, connect, read and write a message over a socket (std::net)
// Also: socket, listen, accept, connect, tcp server, tcp client, network, port, localhost, echo, send, recv, TcpSocket, TcpServerSocket
// expect: server got: hello
// expect: client got: HELLO
import std::io;
import std::net;

fn void? run()
{
	// port 0: the system picks a free port; the connection waits in the backlog until accept
	TcpServerSocket server = tcp::listen("127.0.0.1", 0, 4, REUSEADDR)!;
	defer (void)server.close();
	ushort port = server.local_port()!;

	TcpSocket client = tcp::connect("127.0.0.1", port)!;
	defer (void)client.close();
	TcpSocket conn = tcp::accept(&server)!;   // takes a pointer to the server socket
	defer (void)conn.close();

	client.write("hello")!;                    // a TcpSocket has the methods of Socket: read, write, close...
	char[16] buf;
	sz n = conn.read(&buf)!;
	io::printfn("server got: %s", (String)buf[:n]);

	conn.write("HELLO")!;
	n = client.read(&buf)!;
	io::printfn("client got: %s", (String)buf[:n]);
}

fn void main()
{
	if (catch err = run()) io::printfn("failed: %s", err);
}
