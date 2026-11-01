module m;
const char[*] X = $embed("/etc/passwd");
fn void f()
{
	$for var $i = 0; $i < 4; $i++:
		$echo((int)X[$i]);
	$endfor
}
