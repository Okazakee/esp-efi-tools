/*
 * fake_flasher.c - a stand-in for a vendor firmware flasher.
 *
 * Used only by test/smoke-test.sh. It exists so the smoke test can prove the
 * whole chain works (shell -> startup.nsh -> flash.nsh -> glob -> execute an EFI
 * application -> return) WITHOUT ever shipping, downloading or executing real
 * vendor firmware.
 *
 * It touches nothing: no protocol calls, no file I/O, no flashing, no SPI.
 * It simply returns a distinctive EFI error status. The shell prints that status
 * to the console, which is something no other component can produce - so seeing
 * it in the serial log is proof the application was really loaded and run.
 */
typedef unsigned long long EFI_STATUS;

EFI_STATUS efi_main(void *ImageHandle, void *SystemTable)
{
	(void)ImageHandle;
	(void)SystemTable;
	return 0x8BADF00DULL; /* memorable, and an error so the shell reports it */
}
