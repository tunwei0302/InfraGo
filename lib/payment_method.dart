enum PaymentMethod {
  cash('cash'),
  demoWallet('demo_wallet');

  const PaymentMethod(this.dbValue);

  final String dbValue;
}
