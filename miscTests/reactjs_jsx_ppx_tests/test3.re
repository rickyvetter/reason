[@bs.config {jsx: 3}];

<Foo ref=1 key=1 bar />;
<Foo bar> childOne </Foo>;
<Foo bar> <span /> </Foo>;
<Foo bar> childOne childTwo </Foo>;
<Foo bar> ...(childOne) </Foo>;

<div bar />;
<div bar> childOne </div>;
<div bar> childOne childTwo </div>;
<> <span /> </>;
