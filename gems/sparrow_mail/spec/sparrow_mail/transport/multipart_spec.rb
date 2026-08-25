# frozen_string_literal: true

RSpec.describe SparrowMail::Transport::Multipart do
  let(:boundary) { "BOUNDARY" }

  def encode(fields)
    described_class.encode(fields, boundary)
  end

  it "encodes a simple field" do
    expect(encode({"subject" => "Hello"})).to eq(
      "--BOUNDARY\r\n" \
      "Content-Disposition: form-data; name=\"subject\"\r\n\r\n" \
      "Hello\r\n" \
      "--BOUNDARY--\r\n"
    )
  end

  it "repeats a field once per value, which is how form APIs express lists" do
    body = encode({"to" => ["a@example.org", "b@example.org"]})

    expect(body.scan('name="to"').size).to eq(2)
    expect(body).to include("a@example.org")
    expect(body).to include("b@example.org")
  end

  it "encodes a file part with its filename and content type" do
    part = described_class::FilePart.new("report.csv", "text/csv", "a,b\n")

    expect(encode({"attachment" => part})).to include(
      "Content-Disposition: form-data; name=\"attachment\"; filename=\"report.csv\"\r\n" \
      "Content-Type: text/csv\r\n\r\n" \
      "a,b\n\r\n"
    )
  end

  it "closes the body with the terminating boundary" do
    expect(encode({"a" => "1"})).to end_with("--BOUNDARY--\r\n")
  end

  it "handles an empty field set" do
    expect(encode({})).to eq("--BOUNDARY--\r\n")
  end

  # A filename containing a quote would otherwise break out of the
  # Content-Disposition header and let a caller inject arbitrary MIME.
  it "escapes quotes in a filename" do
    part = described_class::FilePart.new('evil".txt', "text/plain", "x")

    expect(encode({"attachment" => part})).to include('filename="evil%22.txt"')
  end

  it "strips newlines from a filename, which would otherwise inject headers" do
    part = described_class::FilePart.new("a\r\nContent-Type: evil", "text/plain", "x")

    expect(encode({"attachment" => part})).not_to include("Content-Type: evil\r\n")
  end

  # The two together, which is the case that broke.
  #
  # The suite tested a non-ASCII body and it tested attachments, and passed on
  # both, because each alone stays in one encoding. Put them in one message and
  # `parts.join` has to concatenate UTF-8 with ASCII-8BIT, which Ruby refuses.
  # It surfaced as UnknownError on the Mailgun path -- the class documented as
  # "we do not know what happened".
  it "carries a non-ASCII field and binary content in the same body" do
    png = [137, 80, 78, 71, 13, 10, 26, 10, 255, 216, 200].pack("C*")
    part = described_class::FilePart.new("logo.png", "image/png", png)

    body = encode({"subject" => "Código de acceso ☕", "attachment" => part})

    expect(body.encoding).to eq(Encoding::ASCII_8BIT)
    expect(body).to include("Código de acceso ☕".b)
    expect(body).to include(png.b)
  end

  it "carries a non-ASCII filename" do
    part = described_class::FilePart.new("año.pdf", "application/pdf", "x".b)

    expect(encode({"attachment" => part})).to include('filename="año.pdf"'.b)
  end

  # The field name reaches a header, and the Mailgun adapter builds field names
  # from an envelope's custom headers and metadata -- so it is caller-supplied.
  it "escapes a field name that would otherwise rewrite the part's headers" do
    body = encode({"x\"\r\nContent-Disposition: form-data; name=\"to" => "victim@example.com"})

    # The words survive as text inside the name -- harmless. What must not
    # survive is the line break that would make them a header of their own.
    expect(body).not_to include("\r\nContent-Disposition: form-data; name=\"to\"")
    expect(body).to include("%22")
  end

  describe described_class::FilePart do
    it "keeps its content out of inspect, because attachment content is message content" do
      part = described_class.new("secret.txt", "text/plain", "SENSITIVE-ATTACHMENT")

      expect(part.inspect).not_to include("SENSITIVE-ATTACHMENT")
      expect(part.inspect).to include("secret.txt")
    end
  end
end
